import SwiftUI
import ChessKit

/// Play your opening against a club-level bot that plays real club moves, rare ones included.
struct SparView: View {
    let repID: String
    let nodeID: String
    @EnvironmentObject var app: AppModel

    var body: some View {
        if let rep = app.repertoire(repID) {
            SparScreen(rep: rep, startID: nodeID)
                .id(repID + "@" + nodeID)
        } else {
            VStack(spacing: BC.gap) {
                NavBar(title: "Spar")
                EmptyCard(title: "Repertoire not found", message: "This line isn't in your repertoires any more.")
                    .padding(.horizontal, BC.side)
                Spacer()
            }
            .background(Spotlight(colour: BC.blue))
        }
    }
}

private struct SparScreen: View {
    let rep: Repertoire
    let start: RepNode
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var progress: ProgressStore
    @StateObject private var board = BoardState()
    @StateObject private var line = LinePlayer()

    enum Status {
        case yourTurn
        case thinking
        case book(String)                                   // "4.d4"
        case notBook(played: String, mine: RepNode)
        case judging(String)
        case verdict(MoveJudgement, san: String, fenBefore: String)
        case over(String)
        case stuck                                          // the bot found no move, even on a retry
    }

    /// Stockfish's verdict on your last judged move. `at` is the ply count right after it.
    struct LastVerdict {
        let cls: MoveClass
        let san: String
        let judgement: MoveJudgement
        let before: String
        let at: Int
    }

    @State private var plies: [Ply] = []          // every move from the start position
    @State private var fixed = 0                  // moves that came with the starting node (can't take back)
    @State private var inTree: RepNode?
    @State private var status: Status = .thinking
    @State private var leftNote: String?          // "Out of your repertoire: …"
    @State private var paused = false             // waiting for "Keep playing"
    @State private var firstOut = false           // the next judged move is your first reply off the tree
    @State private var generation = 0
    @State private var didSetUp = false
    @State private var lastVerdict: LastVerdict?
    @State private var hinting = false

    private static let owner = "spar"

    init(rep: Repertoire, startID: String) {
        self.rep = rep
        start = rep.node(startID) ?? rep.root
    }

    private var fen: String { plies.last?.fenAfter ?? Chess.startFEN }
    private var myTurn: Bool { Chess.sideToMove(fen) == rep.color }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: "Spar", subtitle: "\(rep.title(for: start)) · bot \(progress.settings.botElo)")
            BoardLayout(reserve: 330 - 44, minBoard: 250) { _ in
                Color.clear.frame(height: 6)
            } board: { size in
                BoardView(state: board, size: size)
            } panel: {
                ScrollView {
                    statusCard
                        .padding(.horizontal, BC.side)
                        .padding(.top, 12)
                        .padding(.bottom, 8)
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: .infinity)
                if paused && !line.isActive {
                    BlockButton(title: "Keep playing", systemImage: "play.fill") { keepPlaying() }
                        .padding(.horizontal, BC.side)
                        .padding(.vertical, 8)
                        .transition(.opacity)
                }
                toolbar
            }
        }
        .background(Spotlight(colour: BC.blue, strength: 0.26))
        .animation(BC.curve(0.25), value: paused)
        .onAppear(perform: setUp)
        .onDisappear {
            generation += 1
            hinting = false
            line.clear()
            Task { await EngineService.shared.stop(owner: Self.owner) }
        }
        .onChange(of: line.isActive) { _, active in if !active { restoreBoard() } }
    }

    // MARK: Status card

    @ViewBuilder
    private var statusCard: some View {
        if line.isActive {
            CardBox(padding: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        LabelText("Best line", colour: BC.mint)
                        Spacer()
                        Button {
                            Feel.tick()
                            line.clear()
                        } label: {
                            Text("Back to game").font(.system(size: 14, weight: .semibold)).foregroundStyle(BC.mute)
                                .frame(minHeight: 30).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    LineStrip(player: line)
                }
            }
        } else {
            CardBox(padding: 16) {
                VStack(alignment: .leading, spacing: 10) { statusContent }
            }
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        switch status {
        case .thinking:
            headline("Bot is thinking…", BC.mute)
            if let leftNote { Text(leftNote).font(.bcBody).foregroundStyle(BC.mute) }
        case .yourTurn:
            if let leftNote {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 15, weight: .bold)).foregroundStyle(BC.coral)
                        .padding(.top, 2)
                    Text(leftNote).font(.bcBodyStrong).foregroundStyle(BC.ink).fixedSize(horizontal: false, vertical: true)
                }
            } else if inTree != nil {
                headline("Your move", BC.ink)
                Text("Play your repertoire move. The bot plays what real club players play.")
                    .font(.bcBody).foregroundStyle(BC.mute).fixedSize(horizontal: false, vertical: true)
            } else {
                headline("Your move", BC.ink)
                if let last = lastVerdict {
                    HStack(spacing: 8) {
                        ClassBadge(cls: last.cls, size: 20)
                        Text("Your \(last.san) was \(last.cls.phrase).").font(.bcBody).foregroundStyle(BC.mute)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                } else {
                    Text("You're on your own now. Stockfish checks each move.")
                        .font(.bcBody).foregroundStyle(BC.mute).fixedSize(horizontal: false, vertical: true)
                }
            }
            yourTurnPills
        case .book(let san):
            HStack(spacing: 8) {
                Tag(text: "Book ✓", colour: BC.mint, filled: true)
                Text(san).font(.bcCardTitle).foregroundStyle(BC.ink)
            }
            Text("Your repertoire move.").font(.bcBody).foregroundStyle(BC.mute)
        case let .notBook(played, mine):
            headline("Not your repertoire move", BC.coral)
            Text("You played \(played). Your move here is \(mine.numbered).")
                .font(.bcBody).foregroundStyle(BC.mute).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button { Feel.tap(); tryAgain() } label: { Label("Try again", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(PillButton())
                Spacer(minLength: 0)
            }
        case .judging(let san):
            headline("Checking \(san)…", BC.mute)
            Text("Stockfish is looking at your move.").font(.bcBody).foregroundStyle(BC.faint)
        case let .verdict(j, san, before):
            HStack(spacing: 8) {
                ClassBadge(cls: j.verdict.cls, size: 24)
                Text("\(san) is \(j.verdict.cls.phrase)")
                    .font(.bcCardTitle).foregroundStyle(j.verdict.cls.isSlip ? j.verdict.cls.colour : BC.ink)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            Text(verdictDetail(j, before: before))
                .font(.bcBody).foregroundStyle(BC.mute).fixedSize(horizontal: false, vertical: true)
            if paused || !j.verdict.cls.isTop {
                HStack(spacing: 8) {
                    // Offered whenever your move wasn't the best, paused or not.
                    Button { Feel.tap(); showBest(j, before: before) } label: { Label("Best move", systemImage: "star.fill") }
                        .buttonStyle(PillButton())
                    if paused {
                        Button { Feel.tick(); tryAgain() } label: { Label("Try again", systemImage: "arrow.uturn.backward") }
                            .buttonStyle(PillButton())
                    }
                    Spacer(minLength: 0)
                }
            }
            if paused {
                QuietButton(title: "Analyse on Board") { analyse() }
                    .padding(.leading, -12)
            }
        case .stuck:
            headline("Couldn't think of a move", BC.coral)
            Text("The bot got stuck in this position. Try again.")
                .font(.bcBody).foregroundStyle(BC.mute).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button { Feel.tap(); retryBot() } label: { Label("Retry", systemImage: "arrow.clockwise") }
                    .buttonStyle(PillButton())
                Spacer(minLength: 0)
            }
        case .over(let text):
            headline(text, BC.ink)
            HStack(spacing: 8) {
                Button { Feel.tap(); restart() } label: { Label("Play again", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(PillButton())
                Button { Feel.tick(); analyse() } label: { Label("Analyse on Board", systemImage: "square.grid.3x3") }
                    .buttonStyle(PillButton())
                Spacer(minLength: 0)
            }
        }
    }

    /// On your turn: a hint, and the best move whenever your last judged move wasn't the best.
    private var yourTurnPills: some View {
        HStack(spacing: 8) {
            Button { Feel.tick(); hint() } label: { Label(hinting ? "Thinking…" : "Hint", systemImage: "lightbulb") }
                .buttonStyle(PillButton(tint: hinting ? BC.mute : BC.ink))
                .disabled(hinting)
            if let last = lastVerdict, !last.cls.isTop, last.at == plies.count - 1 {
                Button { Feel.tap(); showBest(last.judgement, before: last.before) } label: {
                    Label("Best move", systemImage: "star.fill")
                }
                .buttonStyle(PillButton())
            }
            Spacer(minLength: 0)
        }
    }

    private func headline(_ s: String, _ c: Color) -> some View {
        Text(s).font(.bcCardTitle).foregroundStyle(c).lineLimit(1).minimumScaleFactor(0.8)
    }

    private func verdictDetail(_ j: MoveJudgement, before: String) -> String {
        if j.verdict.cls.isTop || j.verdict.cls == .book { return "Exactly right. Stockfish agrees." }
        if let b = j.bestMove, let s = Chess.play(b, on: before) {
            let best = Chess.numbered(s.san, fenBefore: before)
            if [.excellent, .good].contains(j.verdict.cls) { return "Fine. \(best) was a little stronger." }
            return "Best was \(best). Tap Best move to see why."
        }
        return ""
    }

    // MARK: Toolbar

    private var toolbar: some View {
        BoardToolbar {
            ToolbarButton(title: "Take back", systemImage: "arrow.uturn.backward", enabled: plies.count > fixed) { takeBack() }
            ToolbarButton(title: "Restart", systemImage: "arrow.counterclockwise") { restart() }
            ToolbarButton(title: "Flip", systemImage: "arrow.up.arrow.down") {
                withAnimation(BC.curve(0.3)) { board.flipped.toggle() }
            }
            ToolbarButton(title: "Analyse", systemImage: "square.grid.3x3.square", tint: BC.ink) { analyse() }
        }
        .background(BC.sheet.opacity(0.92).ignoresSafeArea(edges: .bottom))
    }

    // MARK: Game flow

    private func setUp() {
        guard !didSetUp else { resume(); return }
        didSetUp = true
        board.flipped = rep.color == .black
        board.showCoordinates = progress.settings.coordinates
        board.userColor = rep.color
        board.onMove = { from, to, promo in userMove(from: from, to: to, promotion: promo) }
        restart()
    }

    /// Back on this screen (e.g. from the Board): whatever was thinking was stopped on the way out, so pick it up.
    private func resume() {
        guard !line.isActive else { return }
        switch status {
        case .judging:
            if let last = plies.last {
                let before = plies.count >= 2 ? plies[plies.count - 2].fenAfter : Chess.startFEN
                judge(last, before: before, san: Chess.numbered(last.san, fenBefore: before))
            }
        case .over, .stuck, .notBook:
            break
        default:
            if !myTurn && !paused && !finished() { botMove(after: 0.3) }
        }
    }

    private func restart() {
        generation += 1
        hinting = false
        line.clear()
        plies = Chess.replay(start.ucis)
        fixed = plies.count
        inTree = start
        leftNote = nil
        lastVerdict = nil
        paused = false
        firstOut = false
        board.clearMarks()
        board.set(fen: fen, lastMove: plies.last.map { MovePair(from: $0.from, to: $0.to) }, animated: false)
        if myTurn { status = .yourTurn } else { botMove() }
    }

    private func setPosition(animated: Bool = true) {
        board.clearMarks()
        board.set(fen: fen, lastMove: plies.last.map { MovePair(from: $0.from, to: $0.to) }, animated: animated)
    }

    private func userMove(from: String, to: String, promotion: Piece.Kind?) {
        guard myTurn, !line.isActive, !paused, let ply = Chess.move(from: from, to: to, promotion: promotion, on: fen) else { return }
        if case .judging = status { return }
        if case .thinking = status { return }
        generation += 1
        let before = fen
        plies.append(ply)
        setPosition(animated: true)
        Feel.move(san: ply.san)
        let san = Chess.numbered(ply.san, fenBefore: before)

        if let n = inTree, let mine = rep.myMove(after: n) {
            if Repertoire.key(mine.fenAfter) == Repertoire.key(ply.fenAfter) {
                inTree = mine
                board.tints = [ply.to: .right]
                Feel.right()
                status = .book(san)
                if !finished() { botMove(after: 0.7) }
            } else {
                Feel.wrong()
                board.tints = [ply.to: .wrong]
                status = .notBook(played: san, mine: mine)
                inTree = nil
                paused = true
            }
            return
        }
        // Off the tree (or past its end): Stockfish judges the move.
        inTree = rep.node(fen: ply.fenAfter)
        judge(ply, before: before, san: san)
    }

    private func judge(_ ply: Ply, before: String, san: String) {
        status = .judging(san)
        let gen = generation
        let wasFirst = firstOut
        Task { @MainActor in
            let j = await Judge.move(ply.uci, from: before, isBook: false, depth: 14, owner: Self.owner,
                                     stillWanted: { gen == generation })
            guard gen == generation else { return }
            guard let j else {
                status = .yourTurn
                if !finished() { botMove(after: 0.4) }
                return
            }
            board.badge = BoardBadge(square: ply.to, cls: j.verdict.cls)
            status = .verdict(j, san: san, fenBefore: before)
            lastVerdict = LastVerdict(cls: j.verdict.cls, san: san, judgement: j, before: before, at: plies.count)
            leftNote = nil
            firstOut = false
            if j.verdict.cls.isSlip { Feel.wrong() } else if j.verdict.cls.isTop { Feel.right() }
            if finished() { return }
            if wasFirst || j.verdict.cls.isSlip {
                paused = true
            } else {
                botMove(after: 1.0)
            }
        }
    }

    private func keepPlaying() {
        paused = false
        board.clearMarks()
        if case .notBook = status {
            // Carry on from your own move: Stockfish judges it first.
            if let last = plies.last {
                let before = plies.count >= 2 ? plies[plies.count - 2].fenAfter : Chess.startFEN
                generation += 1
                inTree = rep.node(fen: last.fenAfter)
                judge(last, before: before, san: Chess.numbered(last.san, fenBefore: before))
            }
            return
        }
        if finished() { return }
        if myTurn { status = .yourTurn } else { botMove() }
    }

    private func tryAgain() {
        guard plies.count > fixed, Chess.sideToMove(fen) != rep.color else { return }
        generation += 1
        line.clear()
        plies.removeLast()
        paused = false
        lastVerdict = nil
        inTree = rep.node(fen: fen)
        setPosition(animated: true)
        status = .yourTurn
    }

    private func takeBack() {
        guard plies.count > fixed else { return }
        generation += 1
        hinting = false
        line.clear()
        paused = false
        lastVerdict = nil
        plies.removeLast()
        if !myTurn && plies.count > fixed { plies.removeLast() }
        inTree = rep.node(fen: fen)
        leftNote = nil
        setPosition(animated: true)
        if myTurn { status = .yourTurn } else { botMove() }
    }

    private func showBest(_ j: MoveJudgement, before: String) {
        guard let pv = j.best.first?.pv, !pv.isEmpty else { return }
        line.play(pv, from: before, on: board, colour: BC.mint, limit: 10)
    }

    private func restoreBoard() {
        setPosition(animated: true)
        if case let .verdict(j, _, _) = status, let last = plies.last {
            board.badge = BoardBadge(square: last.to, cls: j.verdict.cls)
        }
    }

    /// Pushes the Board on this tab, so Back returns here.
    private func analyse() {
        app.open(.board(BoardStart(fen: Chess.startFEN, history: plies.map(\.uci),
                                         title: "Spar · \(rep.title(for: start))", flipped: rep.color == .black)))
    }

    /// Ends the game if it's over. True when it is.
    private func finished() -> Bool {
        switch Chess.outcome(fen) {
        case .checkmate(let winner):
            status = .over(winner == rep.color ? "Checkmate. You win." : "Checkmate. The bot wins.")
            winner == rep.color ? Feel.complete() : Feel.lost()
            paused = false
            return true
        case .draw:
            status = .over("Draw.")
            paused = false
            return true
        default:
            return false
        }
    }

    // MARK: The bot

    private func botMove(after delay: Double = 0.5) {
        let gen = generation
        let position = fen
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard gen == generation else { return }
            if case .book = status {} else { status = .thinking }
            let started = Date()
            var pick = await think(position)
            guard gen == generation else { return }
            if pick == nil {
                // One more go before giving up: a search can come back empty if it was interrupted.
                pick = await think(position)
                guard gen == generation else { return }
            }
            guard let pick, let ply = Chess.play(pick.uci, on: position) else {
                status = .stuck
                return
            }
            // Feel like a person: never instant.
            let spent = Date().timeIntervalSince(started)
            if spent < 0.45 { try? await Task.sleep(nanoseconds: UInt64((0.45 - spent) * 1_000_000_000)) }
            // Don't move under a line you're watching.
            while line.isActive {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard gen == generation else { return }
            }
            guard gen == generation else { return }
            let san = Chess.numbered(ply.san, fenBefore: position)
            plies.append(ply)
            board.clearMarks()
            board.set(fen: ply.fenAfter, lastMove: MovePair(from: ply.from, to: ply.to))
            Feel.move(san: ply.san)
            if finished() { return }
            if let n = inTree {
                let key = Repertoire.key(ply.fenAfter)
                if let child = rep.replies(after: n).first(where: { Repertoire.key($0.fenAfter) == key }) {
                    inTree = child
                    leftNote = rep.myMove(after: child) == nil ? "End of your prep after \(san). Play on: Stockfish checks each move." : nil
                    if rep.myMove(after: child) == nil { firstOut = true }
                } else if let t = rep.node(fen: ply.fenAfter) {
                    inTree = t
                    leftNote = nil
                } else {
                    inTree = nil
                    firstOut = true
                    let share = pick.share.map { " (\(OpeningText.clubShare($0)))" } ?? " (rare in club games)"
                    leftNote = "Out of your repertoire: \(san)\(share). Find a good reply."
                }
            } else {
                inTree = rep.node(fen: ply.fenAfter)
            }
            status = .yourTurn
        }
    }

    /// The bot's move: a real club move from the book when it knows the position, else Stockfish. Nil if neither has one.
    private func think(_ position: String) async -> (uci: String, share: Double?)? {
        if let m = app.book?.humanMove(position), Chess.play(m.uci, on: position) != nil {
            return (m.uci, app.book?.entry(position)?.share(m))
        }
        if let u = await engineMove(position), Chess.play(u, on: position) != nil { return (u, nil) }
        return nil
    }

    private func retryBot() {
        generation += 1
        status = .thinking
        botMove(after: 0.1)
    }

    /// Highlights the piece to move: your repertoire move if there is one, else Stockfish's choice.
    private func hint() {
        guard myTurn, !paused, !line.isActive, !hinting else { return }
        if let n = inTree, let mine = rep.myMove(after: n) {
            board.tints = [mine.from: .hint]
            return
        }
        hinting = true
        let gen = generation
        let position = fen
        Task { @MainActor in
            let lines = await EngineService.shared.analyse(fen: position, depth: 12, multipv: 1, owner: Self.owner)
            hinting = false
            guard gen == generation, fen == position, !line.isActive, let b = lines.first?.best, b.count >= 4 else { return }
            board.tints = [String(b.prefix(2)): .hint]
        }
    }

    /// Stockfish at club strength: a shallow multipv-3 search, then a pick among moves close in value.
    private func engineMove(_ position: String) async -> String? {
        let elo = progress.settings.botElo
        let depth = elo < 900 ? 5 : elo < 1300 ? 7 : elo < 1700 ? 9 : elo < 2100 ? 11 : 13
        let window: Double = elo < 900 ? 220 : elo < 1300 ? 130 : elo < 1700 ? 70 : elo < 2100 ? 35 : 12
        let lines = await EngineService.shared.analyse(fen: position, depth: depth, multipv: 3, owner: Self.owner)
        let me = Chess.sideToMove(position)
        let scored = lines.compactMap { l -> (String, Double)? in
            guard let b = l.best else { return nil }
            return (b, Eval.cp(l, for: me))
        }
        guard let top = scored.map(\.1).max() else { return lines.first?.best }
        let close = scored.filter { top - $0.1 <= window }
        // Closer moves are likelier; weaker bots spread their choice more.
        let weights = close.map { max(0.05, 1 - (top - $0.1) / (window * 1.6)) }
        var r = Double.random(in: 0..<max(0.0001, weights.reduce(0, +)))
        for (i, w) in weights.enumerated() {
            r -= w
            if r < 0 { return close[i].0 }
        }
        return close.first?.0
    }
}
