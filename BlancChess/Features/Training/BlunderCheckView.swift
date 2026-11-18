import SwiftUI
import ChessKit

/// Blunder check: your own slips, in two steps. First see what your move allowed (find their best reply),
/// then find a safe move instead. It trains the one habit that stops most club blunders:
/// "if I play this, what can they do?"
struct BlunderCheckView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: GameStore
    @EnvironmentObject var progress: ProgressStore
    @Environment(\.dismiss) private var dismiss
    @State private var queue: [Puzzle] = []
    @State private var index = 0
    @State private var results: [String: Bool] = [:]
    @State private var loaded = false
    @State private var done = false

    var body: some View {
        VStack(spacing: 0) {
            NavBar(back: "End", title: "Blunder check",
                   subtitle: queue.isEmpty || done ? nil : "\(index + 1) of \(queue.count)") { dismiss() }
            if done {
                summary
            } else if let p = queue[safe: index] {
                capsules.padding(.horizontal, BC.side).padding(.top, 4).padding(.bottom, 10)
                    .readableColumn(BC.boardColumn)
                BlunderCard(puzzle: p, game: store.game(p.gameID)) { clean in
                    results[p.id] = clean
                    progress.recordPuzzle("bc|" + p.progressID, solved: clean)
                    // Not clean: it comes back three positions later, up to twice.
                    let tries = queue.filter { $0.progressID == p.progressID }.count
                    if !clean, tries < 3 { queue.insert(p.again(tries), at: min(queue.count, index + 4)) }
                } onNext: {
                    if index + 1 < queue.count {
                        Feel.next()
                        withAnimation(BC.curve(0.42)) { index += 1 }
                    } else {
                        Feel.complete()
                        withAnimation(BC.curve(0.4)) { done = true }
                    }
                }
                .id(p.id)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)))
            } else if loaded {
                EmptyCard(title: "No slips to check yet",
                          message: store.pendingReviews > 0 ? "Your games are still being reviewed. Come back in a few minutes."
                                                            : "Review a few games and your slips show up here.")
                    .padding(.horizontal, BC.side).padding(.top, 8)
                Spacer()
            } else {
                ProgressView().tint(BC.ink).padding(.top, 80)
                Spacer()
            }
        }
        .background(Spotlight(colour: BC.coral))
        .task {
            guard !loaded else { return }
            guard Pro.shared.use(.blunderRounds) else { loaded = true; dismiss(); return }
            let snap = await TrainingCache.shared.snapshot(store, app.repertoires)
            queue = Self.pick(snap.slips, progress)
            loaded = true
        }
    }

    /// Ten slips that cost material: middlegame first, ones you haven't cleared first, a different mix each time.
    static func pick(_ slips: [Puzzle], _ progress: ProgressStore) -> [Puzzle] {
        let costly = slips.filter { p in
            !p.played.isEmpty && (p.cls == .blunder || p.cls == .mistake || p.cls == .miss)
        }
        func score(_ p: Puzzle) -> Double {
            var s = Double.random(in: 0..<1)
            if p.phase == .middlegame { s += 2 }
            if progress.puzzleState("bc|" + p.id) != true { s += 3 }
            if p.theme == .hungPiece || p.theme == .lostMaterial || p.theme == .allowedMate { s += 1 }
            return s
        }
        return Array(costly.map { ($0, score($0)) }.sorted { $0.1 > $1.1 }.prefix(10).map(\.0))
    }

    private var capsules: some View {
        HStack(spacing: 4) {
            ForEach(Array(queue.enumerated()), id: \.element.id) { i, q in
                Capsule()
                    .fill(i == index ? BC.ink : results[q.id] == true ? BC.mint : results[q.id] == false ? BC.coral : BC.raised2)
                    .frame(height: 4)
            }
        }
        .animation(BC.curve(0.3), value: index)
    }

    private var summary: some View {
        let tried = queue.filter { results[$0.id] != nil }
        let clean = tried.filter { results[$0.id] == true }.count
        return VStack(spacing: 14) {
            Spacer()
            Text("\(clean) of \(tried.count)").font(.bcHero.monospacedDigit()).foregroundStyle(BC.ink)
            Text("checked cleanly").font(.bcBody).foregroundStyle(BC.mute)
            Text("Before every move in your games: what can they do after it? Checks, captures, threats.")
                .font(.bcBody).foregroundStyle(BC.ink).multilineTextAlignment(.center)
                .padding(.horizontal, 30).padding(.top, 8)
            Spacer()
            BlockButton(title: "Ten more", systemImage: "play.fill") {
                guard Pro.shared.use(.blunderRounds) else { return }
                Task {
                    let snap = await TrainingCache.shared.snapshot(store, app.repertoires)
                    queue = Self.pick(snap.slips, progress)
                    results = [:]
                    index = 0
                    withAnimation(BC.curve(0.4)) { done = false }
                }
            }
            .padding(.horizontal, BC.side)
            QuietButton(title: "Done for now") { dismiss() }
                .padding(.bottom, 8)
        }
        .readableColumn()
    }
}

// MARK: - One position

private struct BlunderCard: View {
    let puzzle: Puzzle
    let game: GameRecord?
    let onResult: (Bool) -> Void
    let onNext: () -> Void
    @EnvironmentObject var app: AppModel
    @StateObject private var board = BoardState()

    enum Step { case reply, move, done }
    @State private var step: Step = .reply
    @State private var headline = ""
    @State private var detail = ""
    @State private var tone: Color = BC.ink
    @State private var misses = 0
    @State private var clean = true
    @State private var refutation: EngineLine?
    @State private var bestLine: EngineLine?
    @State private var checking = false
    @State private var shownFEN = ""

    private var me: PieceColor { Chess.sideToMove(puzzle.fen) }
    private var playedPly: Ply? { Chess.play(puzzle.played, on: puzzle.fen) }
    private var afterFEN: String { playedPly?.fenAfter ?? puzzle.fen }
    private var moveName: String { playedPly.map { Chess.numbered($0.san, fenBefore: puzzle.fen) } ?? "that" }

    var body: some View {
        BoardLayout(reserve: 250, minBoard: 260) { size in
            BoardView(state: board, size: size)
        } panel: {
            card.padding(.horizontal, BC.side).padding(.top, 14)
            Spacer(minLength: 8)
            actions.padding(.horizontal, BC.side).padding(.bottom, 8)
        }
        .onAppear(perform: setUp)
        .onDisappear { Task { await EngineService.shared.stop(owner: "blunder") } }
    }

    // MARK: Card

    private var card: some View {
        CardBox(padding: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    LabelText(step == .reply ? "1 · What does it allow?" : step == .move ? "2 · Find a safe move" : "Checked",
                              colour: step == .done ? BC.mint : BC.coral)
                    Spacer()
                    if checking { ProgressView().controlSize(.small).tint(BC.mute) }
                }
                Text(headline).font(.bcCardTitle).foregroundStyle(tone).lineLimit(2).minimumScaleFactor(0.8)
                Text(detail).font(.bcBody).foregroundStyle(BC.mute).lineLimit(3).minimumScaleFactor(0.9)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(height: 104, alignment: .top)
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button("Show me") { reveal() }
                .buttonStyle(PillButton())
                .disabled(step == .done || checking)
                .opacity(step == .done ? 0.4 : 1)
            Button("Analyse") { analyse() }.buttonStyle(PillButton())
            Spacer()
            if step == .done {
                Button { Feel.tap(); onNext() } label: {
                    HStack(spacing: 6) { Text("Next"); Image(systemName: "arrow.right") }
                }
                .buttonStyle(PillButton(filled: true))
            }
        }
    }

    // MARK: Flow

    private func setUp() {
        board.flipped = me == .black
        board.onMove = { from, to, promo in attempt(from: from, to: to, promo: promo) }
        // Step 1: the position after your move. You play their side.
        shownFEN = afterFEN
        board.set(fen: afterFEN, lastMove: playedPly.map { MovePair(from: $0.from, to: $0.to) }, animated: false)
        board.tints = playedPly.map { [$0.to: .wrong] } ?? [:]
        board.userColor = me.opposite
        headline = "You played \(moveName)."
        detail = "Play their best reply. What does your move allow?"
        tone = BC.ink
        checking = true
        Task {
            let lines = await EngineService.shared.analyse(fen: afterFEN, depth: 13, multipv: 1, owner: "blunder")
            refutation = lines.first
            checking = false
            if refutation?.best == nil { startMoveStep(note: nil) }
        }
        // The best eval from the start position, for step 2.
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            let lines = await EngineService.shared.analyse(fen: puzzle.fen, depth: 13, multipv: 1, owner: "blunder-best")
            bestLine = lines.first
        }
    }

    private func attempt(from: String, to: String, promo: Piece.Kind?) {
        guard !checking, let ply = Chess.move(from: from, to: to, promotion: promo, on: shownFEN) else { return }
        switch step {
        case .reply: replyAttempt(ply)
        case .move: moveAttempt(ply)
        case .done: break
        }
    }

    private func replyAttempt(_ ply: Ply) {
        guard let best = refutation?.best, let bestPly = Chess.play(best, on: afterFEN) else { return }
        // Their best reply, or another move that takes on the same square.
        let right = ply.uci == best || (ply.to == bestPly.to && ply.san.contains("x") && bestPly.san.contains("x"))
        board.set(fen: ply.fenAfter, lastMove: MovePair(from: ply.from, to: ply.to))
        Feel.move(san: ply.san)
        if right {
            Feel.right()
            board.tints = [ply.to: .right]
            board.userColor = nil
            headline = "Right: \(Chess.numbered(ply.san, fenBefore: afterFEN))"
            detail = what(bestPly)
            tone = BC.mint
            Task {
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                startMoveStep(note: nil)
            }
        } else {
            Feel.wrong()
            misses += 1
            board.userColor = nil
            headline = "Not their best"
            detail = misses >= 2 ? "Look at \(Chess.numbered(bestPly.san, fenBefore: afterFEN))." : "Look for checks, captures and threats."
            tone = BC.coral
            Task {
                try? await Task.sleep(nanoseconds: 700_000_000)
                board.set(fen: afterFEN, lastMove: playedPly.map { MovePair(from: $0.from, to: $0.to) })
                board.tints = playedPly.map { [$0.to: .wrong] } ?? [:]
                if misses >= 2 { clean = false; board.arrows = [BoardArrow(from: bestPly.from, to: bestPly.to, colour: BC.coral)] }
                board.userColor = me.opposite
            }
        }
    }

    /// "It wins your knight on d5." from what the reply captures.
    private func what(_ reply: Ply) -> String {
        let b = Board64(fen: afterFEN)
        if Chess.outcome(reply.fenAfter) == .checkmate(winner: me.opposite) { return "It's checkmate." }
        if let i = Board64.index(reply.to), let c = b.piece(i), Board64.isWhite(c) == (me == .white) {
            return "It takes your \(Board64.pieceName(c)) on \(reply.to)."
        }
        if let m = refutation?.mate, (m > 0) == (me.opposite == .white) { return "It leads to mate." }
        return "It wins material: follow it through on Analyse."
    }

    private func startMoveStep(note: String?) {
        misses = 0
        step = .move
        shownFEN = puzzle.fen
        board.clearMarks()
        board.set(fen: puzzle.fen, lastMove: lastGameMove)
        board.userColor = me
        headline = "Now find a safe move"
        detail = "Before you play it, ask: what can they do after it?"
        tone = BC.ink
    }

    private var lastGameMove: MovePair? {
        guard let g = game, puzzle.ply > 0, let p = Chess.play(g.ucis[puzzle.ply - 1], on: FenCache.shared.fens(g)[puzzle.ply - 1])
        else { return nil }
        return MovePair(from: p.from, to: p.to)
    }

    private func moveAttempt(_ ply: Ply) {
        board.set(fen: ply.fenAfter, lastMove: MovePair(from: ply.from, to: ply.to))
        board.userColor = nil
        Feel.move(san: ply.san)
        if ply.uci == puzzle.best { accept(ply); return }
        if ply.uci == puzzle.played { reject(ply, "That's the move from your game."); return }
        checking = true
        Task {
            let lines = await EngineService.shared.analyse(fen: ply.fenAfter, depth: 12, multipv: 1, owner: "blunder")
            checking = false
            guard let after = lines.first else { reject(ply, "Couldn't check that one. Try again."); return }
            let best = bestLine.map { Eval.cp($0, for: me) } ?? 0
            let mine = -Eval.cp(after, for: me.opposite)
            if best - mine <= 70 { accept(ply) } else { reject(ply, "That still costs you. What can they do after it?") }
        }
    }

    private func accept(_ ply: Ply) {
        Feel.right()
        board.tints = [ply.to: .right]
        headline = "Safe: \(Chess.numbered(ply.san, fenBefore: puzzle.fen))"
        detail = clean && misses == 0 ? "Checked cleanly." : "Got there. This one comes back to make sure."
        tone = BC.mint
        finish(clean && misses == 0)
    }

    private func reject(_ ply: Ply, _ why: String) {
        Feel.wrong()
        misses += 1
        clean = false
        board.tints = [ply.to: .wrong]
        headline = "Not safe"
        detail = misses >= 2 ? why + " Try \(bestSAN)." : why
        tone = BC.coral
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            board.set(fen: puzzle.fen, lastMove: lastGameMove)
            board.tints = [:]
            if misses >= 2, let b = Chess.play(puzzle.best, on: puzzle.fen) {
                board.arrows = [BoardArrow(from: b.from, to: b.to, colour: BC.mint)]
            }
            board.userColor = me
        }
    }

    private var bestSAN: String {
        Chess.play(puzzle.best, on: puzzle.fen).map { Chess.numbered($0.san, fenBefore: puzzle.fen) } ?? "the best move"
    }

    private func finish(_ ok: Bool) {
        step = .done
        board.userColor = nil
        onResult(ok)
    }

    /// Shows the answer for this step (the step then doesn't count as clean).
    private func reveal() {
        clean = false
        switch step {
        case .reply:
            guard let best = refutation?.best, let p = Chess.play(best, on: afterFEN) else { startMoveStep(note: nil); return }
            board.userColor = nil
            board.set(fen: p.fenAfter, lastMove: MovePair(from: p.from, to: p.to))
            Feel.move(san: p.san)
            headline = "They had \(Chess.numbered(p.san, fenBefore: afterFEN))"
            detail = what(p)
            tone = BC.coral
            Task {
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                startMoveStep(note: nil)
            }
        case .move:
            guard let p = Chess.play(puzzle.best, on: puzzle.fen) else { return }
            board.set(fen: puzzle.fen, lastMove: lastGameMove)
            board.arrows = [BoardArrow(from: p.from, to: p.to, colour: BC.mint)]
            headline = "Safe was \(bestSAN)"
            detail = "This one comes back later in the run."
            tone = BC.mint
            finish(false)
        case .done: break
        }
    }

    /// The board at what's on screen, with the game's moves as history.
    private func analyse() {
        Feel.tick()
        guard let g = game else {
            app.open(.board(BoardStart(fen: shownFEN, title: "Blunder check", flipped: me == .black)))
            return
        }
        var history = Array(g.ucis.prefix(puzzle.ply))
        if step == .reply { history.append(puzzle.played) }
        app.open(.board(BoardStart(fen: g.startFEN, history: history, title: "vs \(g.opponent)", flipped: me == .black)))
    }
}
