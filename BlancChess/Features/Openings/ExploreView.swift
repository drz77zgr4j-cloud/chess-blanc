import SwiftUI
import ChessKit

/// The one board screen for an opening: browse it, learn your moves, try anything and ask Stockfish.
struct ExploreView: View {
    let repID: String
    let nodeID: String
    @EnvironmentObject var app: AppModel

    var body: some View {
        if let rep = app.repertoire(repID) {
            ExploreScreen(rep: rep, startID: nodeID)
                .id(repID + "@" + nodeID)
        } else {
            VStack(spacing: BC.gap) {
                NavBar(title: "Openings")
                EmptyCard(title: "Repertoire not found", message: "This line isn't in your repertoires any more.")
                    .padding(.horizontal, BC.side)
                Spacer()
            }
            .background(Spotlight(colour: BC.blue))
        }
    }
}

private struct ExploreScreen: View {
    let rep: Repertoire
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var progress: ProgressStore
    @StateObject private var board = BoardState()
    @StateObject private var line = LinePlayer()
    @State private var nodeID: String
    @State private var free: [Ply] = []               // moves made off the repertoire, after `node`
    @State private var judgement: MoveJudgement?
    @State private var judgedFor = ""                 // the free ply the judgement belongs to
    @State private var engine: [EngineLine] = []
    @State private var engineFEN = ""
    @State private var generation = 0
    @State private var lineTitle = ""
    @State private var didSetUp = false
    @State private var analysis: Task<Void, Never>?
    @AppStorage("explore.hideAnswer") private var hideAnswer = false
    @AppStorage("explore.engine") private var engineOn = false

    private static let owner = "explore"

    init(rep: Repertoire, startID: String) {
        self.rep = rep
        _nodeID = State(initialValue: rep.node(startID) == nil ? rep.root.id : startID)
    }

    private var node: RepNode { rep.node(nodeID) ?? rep.root }
    private var currentFEN: String { free.last?.fenAfter ?? node.fenAfter }
    private var fenBeforeLastFree: String { free.count >= 2 ? free[free.count - 2].fenAfter : node.fenAfter }
    private var myTurn: Bool { Chess.sideToMove(currentFEN) == rep.color }
    private var myMove: RepNode? { free.isEmpty && myTurn ? rep.myMove(after: node) : nil }
    private var replies: [RepNode] { free.isEmpty && !myTurn ? rep.replies(after: node) : [] }
    private var lastMove: MovePair? {
        if let p = free.last { return MovePair(from: p.from, to: p.to) }
        return node.isRoot ? nil : node.move
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: rep.title(for: node), subtitle: subtitle)
            BoardLayout(reserve: 372 - 44, minBoard: 250) { _ in
                OpeningMoveStrip(items: stripItems, current: stripCurrent, tap: tapStrip)
                    .padding(.bottom, 6)
            } board: { boardSize in
                BoardView(state: board, size: boardSize)
            } panel: {
                if engineOn { engineArea.padding(.horizontal, BC.side).padding(.top, 8) }
                ScrollView {
                    panel
                        .padding(.horizontal, BC.side)
                        .padding(.top, 10)
                        .padding(.bottom, 8)
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: .infinity)
                if free.isEmpty && !line.isActive {
                    // Off the repertoire there's nothing of yours to practise: the panel gets the room instead.
                    BlockButton(title: "Practise from here", systemImage: "play.fill", enabled: canPractise) {
                        let target = rep.continuing(node)
                        app.open(.practice(PracticeRequest(repID: rep.id, mode: .all, nodeID: target.id, title: rep.title(for: node))))
                    }
                    .padding(.horizontal, BC.side)
                    .padding(.vertical, 8)
                }
                toolbar
            }
        }
        .background(Spotlight(colour: BC.blue, strength: 0.26))
        .onAppear(perform: setUp)
        .onDisappear {
            // Leaving (or pushing Spar on top): drop any search in flight; onAppear restarts it.
            generation += 1
            analysis?.cancel()
            analysis = nil
            line.clear()
            Task { await EngineService.shared.stop(owner: Self.owner) }
        }
        .onChange(of: hideAnswer) { _, _ in refreshMarks() }
        .onChange(of: line.isActive) { _, active in if !active { restoreBoard() } }
    }

    private var subtitle: String { free.isEmpty ? node.moveTextTail() : "Off your repertoire" }

    private var canPractise: Bool { !rep.myMoves(under: rep.continuing(node).id).isEmpty || rep.myMove(after: node) != nil }

    // MARK: Move strip

    private var stripItems: [OpeningMoveStrip.Item] {
        var items = [OpeningMoveStrip.Item(id: "start", text: "Start")]
        items += node.path.map { OpeningMoveStrip.Item(id: $0.id, text: $0.numbered) }
        var fen = node.fenAfter
        for (i, p) in free.enumerated() {
            items.append(OpeningMoveStrip.Item(id: "free-\(i)", text: Chess.numbered(p.san, fenBefore: fen), offBook: true))
            fen = p.fenAfter
        }
        return items
    }

    private var stripCurrent: String {
        if !free.isEmpty { return "free-\(free.count - 1)" }
        return node.isRoot ? "start" : node.id
    }

    private func tapStrip(_ id: String) {
        if id.hasPrefix("free-"), let i = Int(id.dropFirst(5)) {
            guard i < free.count - 1 else { return }
            free = Array(free.prefix(i + 1))
            positionChanged()
            return
        }
        let target = id == "start" ? rep.root : (rep.node(id) ?? rep.root)
        go(target, sound: false)
    }

    // MARK: Panel

    @ViewBuilder
    private var panel: some View {
        if line.isActive {
            linePanel
        } else if let last = free.last {
            offBookCard(last)
        } else if let m = myMove {
            yourMoveCard(m)
        } else if !replies.isEmpty {
            repliesList
        } else {
            leafCard
        }
    }

    private var linePanel: some View {
        CardBox(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    LabelText(lineTitle, colour: BC.ink)
                    Spacer()
                    Button {
                        Feel.tick()
                        line.clear()
                    } label: {
                        Text("Done").font(.system(size: 14, weight: .semibold)).foregroundStyle(BC.mute)
                            .frame(minHeight: 30).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                LineStrip(player: line)
            }
        }
    }

    private func yourMoveCard(_ m: RepNode) -> some View {
        let due = progress.isDue(rep, m)
        let state = progress.state(rep, m)
        return CardBox(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(hideAnswer ? "Your move: ?" : "Your move: \(m.numbered)")
                        .font(.bcCardTitle).foregroundStyle(BC.ink).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 8)
                    Tag(text: due ? "Due" : state.label, colour: due ? BC.coral : state.colour)
                }
                Text(hideAnswer ? "Play it on the board to test yourself." : m.whyLine)
                    .font(.bcBody).foregroundStyle(BC.mute)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button {
                        Feel.tap()
                        go(m, sound: true)
                    } label: {
                        Label("Play it", systemImage: "arrow.right")
                    }
                    .buttonStyle(PillButton())
                    Chip(title: hideAnswer ? "Show answer" : "Hide answer",
                         systemImage: hideAnswer ? "eye" : "eye.slash", active: hideAnswer) {
                        withAnimation(BC.curve(0.25)) { hideAnswer.toggle() }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var repliesList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                LabelText("Their replies")
                Spacer()
                Text("Tap one, or play any move").font(.system(size: 12)).foregroundStyle(BC.faint)
            }
            .padding(.horizontal, 4)
            RowGroup {
                ForEach(replies) { r in
                    Button {
                        Feel.tick()
                        go(r, sound: true)
                    } label: {
                        replyRow(r)
                    }
                    .buttonStyle(PressStyle())
                }
            }
        }
    }

    private func replyRow(_ r: RepNode) -> some View {
        let answer = rep.myMove(after: r)
        return HStack(spacing: 12) {
            Text(r.numbered).font(.system(size: 16, weight: .semibold).monospacedDigit()).foregroundStyle(BC.ink)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(width: 82, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(r.share > 0 ? r.percent : "rare")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(BC.mute)
                    if r.isTrap { Tag(text: "Trap", colour: BC.amber) }
                    Spacer(minLength: 0)
                }
                ResultsBar(results: r.results, me: rep.color)
            }
            if let a = answer {
                StateDot(state: progress.state(rep, a), due: progress.isDue(rep, a))
            }
            Image(systemName: "chevron.forward").font(.system(size: 12, weight: .semibold)).foregroundStyle(BC.mute)
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    private var leafCard: some View {
        CardBox(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                LabelText("End of your prep")
                Text("Your lines stop here. Stockfish rates it \(Eval.text(cp: node.eval, mate: nil)).")
                    .font(.bcBody).foregroundStyle(BC.mute).fixedSize(horizontal: false, vertical: true)
                if !node.continuation.isEmpty {
                    Button {
                        Feel.tap()
                        playLine(node.continuation, from: node.fenAfter, title: "Where it goes", colour: BC.violet)
                    } label: {
                        Label("Where it goes", systemImage: "play.fill")
                    }
                    .buttonStyle(PillButton())
                }
            }
        }
    }

    private func offBookCard(_ last: Ply) -> some View {
        let before = fenBeforeLastFree
        let mover = Chess.sideToMove(before)
        let share = clubShare(of: last.uci, at: before, book: app.book)
        let j = judgedFor == judgeKey ? judgement : nil
        return CardBox(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    LabelText("Not in your repertoire", colour: BC.coral)
                    Spacer()
                    Text(Chess.numbered(last.san, fenBefore: before))
                        .font(.system(size: 15, weight: .bold).monospacedDigit()).foregroundStyle(BC.ink)
                }
                Text(shareText(share, san: last.san))
                    .font(.bcBody).foregroundStyle(BC.mute).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if let j {
                        ClassBadge(cls: j.verdict.cls, size: 22)
                        Text(verdictText(j, san: last.san, mover: mover, before: before))
                            .font(.bcBodyStrong).foregroundStyle(BC.ink)
                            .lineLimit(2).minimumScaleFactor(0.85).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Circle().fill(BC.violet.opacity(0.5)).frame(width: 8, height: 8)
                        Text("Stockfish is checking it…").font(.bcBody).foregroundStyle(BC.mute)
                    }
                }
                .frame(minHeight: 24)
                HStack(spacing: 8) {
                    Button {
                        Feel.tap()
                        showBest(last, before: before, mover: mover)
                    } label: {
                        Label("Best move", systemImage: "star.fill")
                    }
                    .buttonStyle(PillButton(tint: j == nil ? BC.mute : BC.ink))
                    .disabled(j == nil)
                    Button {
                        Feel.tick()
                        stepBack()
                    } label: {
                        Label("Take back", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(PillButton())
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func shareText(_ share: Double?, san: String) -> String {
        guard let share else { return "Club players almost never reach this position." }
        if share <= 0 { return "Club players almost never play \(san) here." }
        return "Club players choose \(san) in \(OpeningText.clubShare(share))."
    }

    private func verdictText(_ j: MoveJudgement, san: String, mover: PieceColor, before: String) -> String {
        let head = "\(san) is \(j.verdict.cls.phrase)."
        if mover == rep.color {
            if free.count == 1, let mine = rep.myMove(after: node) { return head + " Yours is \(mine.san)." }
            if let b = j.bestMove, j.verdict.cls != .best, let s = Chess.play(b, on: before)?.san { return head + " Best is \(s)." }
            return head
        }
        if let r = j.bestReply, let after = free.last?.fenAfter, let s = Chess.play(r, on: after) {
            return head + " Best reply: \(Chess.numbered(s.san, fenBefore: after))."
        }
        return head
    }

    private var judgeKey: String { free.map(\.uci).joined(separator: ",") + "@" + node.id }

    // MARK: Engine

    private var engineArea: some View {
        let fresh = engineFEN == currentFEN ? engine.first : nil
        return HStack(spacing: 10) {
            EvalBar(cp: fresh?.cp, mate: fresh?.mate, height: 22)
                .frame(width: 84)
                .opacity(fresh == nil ? 0.4 : 1)
            Text(engineLineText(fresh))
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(fresh == nil ? BC.faint : BC.mute)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 26)
    }

    private func engineLineText(_ l: EngineLine?) -> String {
        guard let l else { return "Stockfish is thinking…" }
        return Chess.sanLine(l.pv, from: currentFEN, limit: 8).joined(separator: " ")
    }

    // MARK: Toolbar

    private var toolbar: some View {
        BoardToolbar {
            ToolbarButton(title: "Back", systemImage: "chevron.backward", enabled: line.isActive || !free.isEmpty || !node.isRoot) {
                stepBack()
            }
            ToolbarButton(title: "Flip", systemImage: "arrow.up.arrow.down") {
                withAnimation(BC.curve(0.3)) { board.flipped.toggle() }
            }
            ToolbarButton(title: "Engine", systemImage: engineOn ? "cpu.fill" : "cpu", tint: engineOn ? BC.violet : BC.ink) {
                toggleEngine()
            }
            ToolbarButton(title: "Spar", systemImage: "figure.fencing") {
                app.open(.spar(rep: rep.id, node: node.id))
            }
        }
        .background(BC.sheet.opacity(0.92).ignoresSafeArea(edges: .bottom))
    }

    // MARK: Actions

    private func toggleEngine() {
        withAnimation(BC.curve(0.25)) { engineOn.toggle() }
        if engineOn { startAnalysis() } else {
            generation += 1
            analysis?.cancel()
            analysis = nil
            engine = []
            refreshMarks()
            Task { await EngineService.shared.stop(owner: Self.owner) }
        }
    }

    private func setUp() {
        guard !didSetUp else {
            // Back on this screen (e.g. from Spar): the search was stopped on the way out, so start it again.
            restoreBoard()
            let unjudged = free.last != nil && !(judgedFor == judgeKey && judgement != nil)
            if engineOn || unjudged { startAnalysis() }
            return
        }
        didSetUp = true
        board.flipped = rep.color == .black
        board.bothSides = true
        board.showCoordinates = progress.settings.coordinates
        board.set(fen: currentFEN, lastMove: lastMove, animated: false)
        board.onMove = { from, to, promo in handleMove(from: from, to: to, promotion: promo) }
        refreshMarks()
        startAnalysis()
    }

    private func go(_ target: RepNode, sound: Bool) {
        line.clear()
        free = []
        judgement = nil
        nodeID = target.id
        board.clearMarks()
        board.set(fen: target.fenAfter, lastMove: target.isRoot ? nil : target.move)
        if sound && !target.isRoot { Feel.move(san: target.san) }
        refreshMarks()
        startAnalysis()
    }

    private func stepBack() {
        if line.isActive { line.clear(); return }
        if !free.isEmpty {
            free.removeLast()
            positionChanged()
            return
        }
        if let p = node.parent { go(p, sound: false) }
    }

    private func positionChanged() {
        board.clearMarks()
        board.set(fen: currentFEN, lastMove: lastMove)
        refreshMarks()
        startAnalysis()
    }

    private func handleMove(from: String, to: String, promotion: Piece.Kind?) {
        guard !line.isActive, let ply = Chess.move(from: from, to: to, promotion: promotion, on: currentFEN) else { return }
        let key = Repertoire.key(ply.fenAfter)
        if free.isEmpty, let child = rep.continuing(node).children.first(where: { Repertoire.key($0.fenAfter) == key }) {
            let testing = child.mover == rep.color && hideAnswer
            go(child, sound: true)
            if testing {
                Feel.right()
                board.tints = [child.to: .right]
            }
            return
        }
        if let back = rep.node(fen: ply.fenAfter) {
            // Transposed back into the repertoire.
            go(back, sound: true)
            return
        }
        free.append(ply)
        judgement = nil
        board.clearMarks()
        board.set(fen: ply.fenAfter, lastMove: MovePair(from: ply.from, to: ply.to))
        Feel.move(san: ply.san)
        refreshMarks()
        startAnalysis()
    }

    private func showBest(_ last: Ply, before: String, mover: PieceColor) {
        guard let j = judgedFor == judgeKey ? judgement : nil else { return }
        if mover == rep.color, let pv = j.best.first?.pv, !pv.isEmpty {
            playLine(pv, from: before, title: "Best line", colour: BC.mint)
        } else if let pv = j.after?.pv, !pv.isEmpty {
            playLine(pv, from: last.fenAfter, title: "Best reply", colour: BC.mint)
        }
    }

    private func playLine(_ pv: [String], from fen: String, title: String, colour: Color) {
        lineTitle = title
        line.play(pv, from: fen, on: board, colour: colour, limit: 10)
    }

    private func restoreBoard() {
        board.clearMarks()
        board.set(fen: currentFEN, lastMove: lastMove)
        if let last = free.last, judgedFor == judgeKey, let j = judgement {
            board.badge = BoardBadge(square: last.to, cls: j.verdict.cls)
        }
        refreshMarks()
    }

    private func refreshMarks() {
        guard !line.isActive else { return }
        var arrows: [BoardArrow] = []
        if let m = myMove, !hideAnswer {
            arrows.append(BoardArrow(from: m.from, to: m.to, colour: BC.arrow, opacity: 0.8))
        }
        if engineOn, engineFEN == currentFEN, let best = engine.first?.best, best.count >= 4 {
            let a = BoardArrow(from: String(best.prefix(2)), to: String(best.dropFirst(2).prefix(2)), colour: BC.violet, opacity: 0.75)
            if !arrows.contains(where: { $0.from == a.from && $0.to == a.to }) { arrows.append(a) }
        }
        board.arrows = arrows
    }

    /// Judges the last off-book move (if any), then runs the engine on the position (if on). Never blocks the UI.
    private func startAnalysis() {
        generation += 1
        let gen = generation
        let fen = currentFEN
        let key = judgeKey
        let last = free.last
        let before = fenBeforeLastFree
        let depth = max(12, progress.settings.engineDepth)
        let alreadyJudged = judgedFor == key && judgement != nil
        analysis?.cancel()
        analysis = nil
        guard (last != nil && !alreadyJudged) || engineOn else { return }
        analysis = Task { @MainActor in
            if let last, !alreadyJudged {
                let j = await Judge.move(last.uci, from: before, isBook: false, depth: 14, owner: Self.owner,
                                         stillWanted: { gen == generation })
                guard !Task.isCancelled, gen == generation else { return }
                judgement = j
                judgedFor = key
                if let j, !line.isActive {
                    board.badge = BoardBadge(square: last.to, cls: j.verdict.cls)
                    if let a = j.after, engineOn {
                        engine = [a]
                        engineFEN = fen
                        refreshMarks()
                    }
                }
            }
            guard engineOn, !Task.isCancelled, gen == generation else { return }
            await EngineService.shared.analyse(fen: fen, depth: depth, multipv: 1, owner: Self.owner) { lines in
                MainActor.assumeIsolated {
                    guard gen == generation, let top = lines.first else { return }
                    // Never step back to a shallower line for the same position.
                    if engineFEN == fen, let shown = engine.first, shown.depth > top.depth { return }
                    engine = lines
                    engineFEN = fen
                    refreshMarks()
                }
            }
        }
    }
}
