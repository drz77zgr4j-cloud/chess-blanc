import SwiftUI
import ChessKit

/// A run of positions from your games: a list first (what's fixed, what to retry), then one board to solve them on.
struct PuzzleRunView: View {
    let set: PuzzleSet
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: GameStore
    @EnvironmentObject var progress: ProgressStore
    @Environment(\.dismiss) private var dismiss

    enum Stage: Equatable { case list, solve, summary }

    @State private var all: [Puzzle] = []
    @State private var loaded = false
    @State private var filter = "all"
    @State private var stage: Stage = .list
    @State private var queue: [Puzzle] = []
    @State private var index = 0
    @State private var results: [String: Bool] = [:]

    private var light: Color { app.tab.light }

    var body: some View {
        ZStack {
            switch stage {
            case .list:
                list.transition(.move(edge: .leading).combined(with: .opacity))
            case .solve:
                PuzzleSolveView(puzzles: $queue, index: $index, results: $results, colour: light,
                                onList: { show(.list) }, onFinish: { show(.summary) })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            case .summary:
                summary.transition(.opacity)
            }
        }
        .background(Spotlight(colour: light, strength: 0.24))
        .task { await load() }
        .onChange(of: store.revision) { _, _ in if stage == .list { Task { await load() } } }
    }

    private func show(_ s: Stage) {
        withAnimation(BC.curve(0.38)) { stage = s }
    }

    private func load() async {
        all = await TrainingCache.shared.puzzles(for: set.source, store, app.repertoires, progress)
        loaded = true
        switch PuzzleLaunch.take(for: set) {
        case .at(let id)?:
            if let i = all.firstIndex(where: { $0.id == id }) { start(all, at: i, animated: false) }
        case .first?:
            startTodoFirst(all, animated: false)
        case nil:
            break
        }
    }

    // MARK: List

    private var filters: [(String, String)] {
        var out: [(String, String)] = [("all", "All")]
        if all.contains(where: { progress.puzzleState($0.id) != true }) && all.contains(where: { progress.puzzleState($0.id) == true }) {
            out.append(("todo", "Not fixed"))
        }
        if all.contains(where: \.isChallenge) && all.contains(where: { !$0.isChallenge }) {
            out.append(("slips", "Your slips"))
            out.append(("chances", "Chances"))
        }
        for c in [MoveClass.blunder, .mistake, .miss] where all.filter({ $0.cls == c && !$0.isChallenge }).count >= 2 && Set(all.map(\.cls)).count > 1 {
            out.append((c.rawValue, c == .miss ? "Misses" : c.title + "s"))
        }
        let phases = Phase.allCases.filter { ph in all.contains { $0.phase == ph } }
        if phases.count > 1 { out += phases.map { ($0.rawValue, $0.rawValue) } }
        return out
    }

    private var shown: [Puzzle] {
        all.filter { p in
            switch filter {
            case "all": true
            case "todo": progress.puzzleState(p.id) != true
            case "slips": !p.isChallenge
            case "chances": p.isChallenge
            case "blunder", "mistake", "miss": p.cls.rawValue == filter && !p.isChallenge
            default: p.phase.rawValue == filter
            }
        }
    }

    private var list: some View {
        let items = shown
        let fixed = items.filter { progress.puzzleState($0.id) == true }.count
        let missed = items.filter { progress.puzzleState($0.id) == false }.count
        return VStack(spacing: 0) {
            NavBar(title: set.title)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if !loaded {
                        EmptyView()
                    } else if all.isEmpty {
                        empty.padding(.top, 8)
                    } else {
                        header(count: items.count, fixed: fixed, missed: missed)
                        if filters.count > 1 {
                            ChipPicker(options: filters, selection: $filter).padding(.vertical, 4)
                        }
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, p in
                            Button { start(items, at: i) } label: { row(p) }
                                .buttonStyle(PressStyle())
                                .arrive(min(i, 8))
                        }
                    }
                }
                .padding(.horizontal, BC.side)
                .padding(.top, 6)
                .padding(.bottom, 130)
                .readableColumn()
            }
            .scrollIndicators(.hidden)
        }
        .overlay(alignment: .bottom) {
            if !items.isEmpty {
                HStack(spacing: 10) {
                    BlockButton(title: missed + (items.count - fixed - missed) > 0 ? "Start" : "Go again", systemImage: "play.fill") {
                        startTodoFirst(items)
                    }
                    Button {
                        Feel.tick()
                        start(items.shuffled(), at: 0)
                    } label: {
                        Image(systemName: "shuffle").font(.system(size: 18, weight: .bold)).foregroundStyle(BC.ink)
                            .frame(width: 56, height: 56)
                            .background(BC.card, in: Circle())
                            .overlay(Circle().stroke(BC.line, lineWidth: 1))
                    }
                    .buttonStyle(PressStyle())
                    .accessibilityLabel("Shuffle and start")
                }
                .padding(.horizontal, BC.side).padding(.top, 24).padding(.bottom, 8)
                .readableColumn()
                .background(LinearGradient(colors: [.black.opacity(0), .black.opacity(0.92), .black], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea())
            }
        }
    }

    private func header(count: Int, fixed: Int, missed: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(count)").font(.system(size: 40, weight: .bold).monospacedDigit()).tracking(-1).foregroundStyle(BC.ink)
                Text(count == 1 ? "position" : "positions").font(.bcBodyStrong).foregroundStyle(BC.mute)
                Spacer()
            }
            HStack(spacing: 0) {
                Text("\(fixed) fixed").foregroundStyle(BC.mint)
                Text("  ·  ").foregroundStyle(BC.faint)
                Text("\(missed) to retry").foregroundStyle(missed > 0 ? BC.coral : BC.mute)
                Text("  ·  ").foregroundStyle(BC.faint)
                Text("\(count - fixed - missed) new").foregroundStyle(BC.mute)
            }
            .font(.system(size: 13, weight: .semibold).monospacedDigit())
            .lineLimit(1).minimumScaleFactor(0.8)
            ProgressBar(value: Double(fixed) / Double(max(1, count)), colour: BC.mint)
        }
        .padding(.bottom, 4)
    }

    private func row(_ p: Puzzle) -> some View {
        let st = PuzzleStatus(progress.puzzleState(p.id))
        return HStack(spacing: 12) {
            SlipBoard(fen: p.fen, size: 64, flipped: p.side == .black, move: p.isChallenge ? nil : p.playedMove)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(p.listTitle).font(.bcRowTitle).foregroundStyle(BC.ink).lineLimit(1).minimumScaleFactor(0.8)
                    if !p.isChallenge && p.cls != .book {
                        Text(p.cls.symbol).font(.system(size: 14, weight: .heavy)).foregroundStyle(p.cls.colour)
                    }
                }
                Text("vs \(p.opponent) · \(p.phase.rawValue.lowercased())")
                    .font(.bcCaption).foregroundStyle(BC.mute).lineLimit(1)
                Text(st.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(st.colour)
            }
            Spacer(minLength: 0)
            Image(systemName: st == .fixed ? "checkmark.circle.fill" : st == .missed ? "arrow.counterclockwise.circle.fill" : "chevron.forward")
                .font(.system(size: st == .new ? 13 : 20, weight: .semibold))
                .foregroundStyle(st.colour)
        }
        .padding(11)
        .background(BC.card, in: RoundedRectangle(cornerRadius: BC.rRow, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BC.rRow, style: .continuous).stroke(BC.line, lineWidth: 1))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var empty: some View {
        if !progress.settings.linked {
            EmptyCard(title: "No games yet", message: "Link your chess.com account and your slips become positions to fix.",
                      actionTitle: "Link chess.com") { app.open(.link) }
        } else if store.reviewed.isEmpty {
            EmptyCard(title: "Reviewing your games",
                      message: store.pendingReviews > 0
                        ? "\(store.pendingReviews) game\(store.pendingReviews == 1 ? "" : "s") in the queue. Positions show up here as reviews finish."
                        : "Review a few games and the positions you got wrong show up here.")
        } else {
            EmptyCard(title: "Nothing to fix here", message: "No positions like this in your reviewed games. That's good news.")
        }
    }

    private func start(_ items: [Puzzle], at i: Int, animated: Bool = true) {
        guard !items.isEmpty else { return }
        guard Pro.shared.left(.positions) > 0 else { Pro.shared.paywall = .positions; return }
        queue = items
        index = i
        results = [:]
        if animated { Feel.next(); show(.solve) } else { stage = .solve }
    }

    /// What isn't fixed yet first, then the rest.
    private func startTodoFirst(_ items: [Puzzle], animated: Bool = true) {
        let todo = items.filter { progress.puzzleState($0.id) != true }
        start(todo.isEmpty ? items : todo + items.filter { progress.puzzleState($0.id) == true }, at: 0, animated: animated)
    }

    // MARK: Summary

    private var summary: some View {
        let tried = queue.filter { results[$0.id] != nil }
        let solved = tried.filter { results[$0.id] == true }.count
        return VStack(spacing: 0) {
            NavBar(title: set.title, onBack: { show(.list) })
            Spacer()
            VStack(spacing: 14) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.08), lineWidth: 8)
                    Circle().trim(from: 0, to: Double(solved) / Double(max(1, tried.count)))
                        .stroke(BC.mint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .shadow(color: BC.mint.opacity(0.5), radius: 8)
                    VStack(spacing: 0) {
                        Text("\(solved)").font(.bcRing).foregroundStyle(BC.ink)
                        Text("of \(tried.count)").font(.bcBodyStrong).foregroundStyle(BC.mute)
                    }
                }
                .frame(width: 150, height: 150)
                Text(solved == tried.count && solved > 0 ? "All solved first try" : "\(solved) of \(tried.count) solved first try")
                    .font(.bcSheetTitle).foregroundStyle(BC.ink).multilineTextAlignment(.center)
                Text(tried.count - solved > 0 ? "The ones you missed stay in the list to retry." : "Every one of these is fixed.")
                    .font(.bcBody).foregroundStyle(BC.mute).multilineTextAlignment(.center)
            }
            .padding(.horizontal, BC.side)
            .arrive()
            Spacer()
            BlockButton(title: "Done") { show(.list) }
                .padding(.horizontal, BC.side).padding(.bottom, 12)
                .readableColumn()
        }
        .onAppear { Feel.complete() }
    }
}

// MARK: - Solving

/// One board for the whole run. Each position slides in; the first try is what counts.
struct PuzzleSolveView: View {
    @Binding var puzzles: [Puzzle]
    @Binding var index: Int
    @Binding var results: [String: Bool]
    var colour: Color = BC.coral
    let onList: () -> Void
    let onFinish: () -> Void
    @State private var flips = 0
    @State private var forward = true

    private var p: Puzzle { puzzles[min(index, puzzles.count - 1)] }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(back: "List", title: "\(index + 1) of \(puzzles.count)", onBack: onList) {
                Button {
                    Feel.tick()
                    flips += 1
                } label: {
                    Image(systemName: "arrow.up.arrow.down").font(.system(size: 15, weight: .semibold)).foregroundStyle(BC.mute)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Flip the board")
            }
            capsules.padding(.horizontal, BC.side).padding(.top, 4).padding(.bottom, 10)
                .readableColumn(BC.boardColumn)
            ZStack {
                PuzzleCard(puzzle: p, number: index, flips: flips, colour: colour,
                           isLast: index + 1 >= puzzles.count,
                           onResult: { solved in
                               results[p.id] = solved
                               // Missed: it comes back three positions later, up to twice, until it's solved cleanly.
                               let tries = puzzles.filter { $0.progressID == p.progressID }.count
                               if !solved, tries < 3 {
                                   puzzles.insert(p.again(tries), at: min(puzzles.count, index + 4))
                               }
                           },
                           onNext: next)
                    .id(p.id)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .move(edge: .leading).combined(with: .opacity)))
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .clipped()
        }
    }

    @ViewBuilder
    private var capsules: some View {
        if puzzles.count <= 24 {
            HStack(spacing: 4) {
                ForEach(Array(puzzles.enumerated()), id: \.element.id) { i, q in
                    Capsule()
                        .fill(i == index ? BC.ink : results[q.id] == true ? BC.mint : results[q.id] == false ? BC.coral : BC.raised2)
                        .frame(height: 4)
                }
            }
            .animation(BC.curve(0.3), value: index)
        } else {
            ProgressBar(value: Double(index) / Double(puzzles.count), colour: BC.ink, height: 4)
        }
    }

    private func next() {
        guard index + 1 < puzzles.count else { onFinish(); return }
        if Pro.shared.left(.positions) == 0 { onFinish(); Pro.shared.paywall = .positions; return }
        Feel.next()
        withAnimation(BC.curve(0.42)) { index += 1 }
    }
}


/// One position: the board, the prompt, and what you can do.
///
/// What the board shows is one of three things:
/// - the game (`gameAt` = plies of the game shown, view-only), reached with ‹ from the puzzle;
/// - Stockfish's line (`lineAt` = moves of `linePlies` shown from the puzzle position), once it's loaded;
/// - live: the puzzle as you're solving it (`status`, `liveMove`, hints), when neither of the above.
/// Going forward out of the game always lands back on the line (if loaded) or live, exactly as it was.
private struct PuzzleCard: View {
    let puzzle: Puzzle
    let number: Int
    let flips: Int
    let colour: Color
    let isLast: Bool
    let onResult: (Bool) -> Void
    let onNext: () -> Void

    @EnvironmentObject var progress: ProgressStore
    @EnvironmentObject var store: GameStore
    @EnvironmentObject var app: AppModel
    @StateObject private var board = BoardState()

    enum Status: Equatable { case solving, checking, wrong, solved, revealed }
    @State private var status: Status = .solving
    @State private var note = ""
    @State private var graded = false
    @State private var hinted = false
    @State private var ready = false
    @State private var checkTask: Task<Void, Never>?

    /// The game up to the puzzle: where it started and every move before it.
    @State private var base = ""
    @State private var history: [Ply] = []
    @State private var userColor: PieceColor = .white
    @State private var lastMark = ""             // "??" when the move before was a blunder, "?" a mistake
    /// Browsing the game: how many of its plies are shown. nil = not browsing.
    @State private var gameAt: Int?
    /// Stockfish's line from the puzzle position, and how many of its moves are shown.
    @State private var linePlies: [Ply] = []
    @State private var lineAt = 0
    /// Your move as it stands on the live board (checking, solved, or a wrong try before it's taken back).
    @State private var liveMove: Ply?
    @State private var exact = false

    private static let owner = "puzzle-run"
    /// Everything under the nav that isn't the board: header, card, bottom bar.
    private static let reserved: CGFloat = 266

    var body: some View {
        BoardLayout(reserve: Self.reserved) { _ in
            header.padding(.horizontal, BC.side).padding(.bottom, 10)
        } board: { size in
            BoardView(state: board, size: size)
        } panel: {
            card.padding(.horizontal, BC.side).padding(.top, 12)
            Spacer(minLength: 8)
            bar.padding(.horizontal, BC.side).padding(.bottom, 8)
        }
        .animation(BC.curve(0.3), value: status)
        .onAppear(perform: setUp)
        .onDisappear {
            checkTask?.cancel()
            checkTask = nil
            // A check cut short isn't graded: back to the position.
            if status == .checking {
                status = .solving
                note = ""
                render(animated: false)
            }
            Task { await EngineService.shared.stop(owner: Self.owner) }
        }
        .onChange(of: flips) { _, _ in
            withAnimation(BC.curve(0.35)) { board.flipped.toggle() }
        }
    }

    // MARK: Header

    /// "14…Qxb2": the move that led to the puzzle.
    private var lastText: String? {
        guard let last = history.last else { return nil }
        return Chess.numbered(last.san, fenBefore: fen(at: history.count - 1))
    }

    private var header: some View {
        var bits = ["vs \(puzzle.opponent)", puzzle.date.formatted(.dateTime.day().month())]
        if let lastText, puzzle.kind != .punish { bits.insert("after \(lastText)", at: 0) }
        else { bits.append(puzzle.phase.rawValue.lowercased()) }
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(puzzle.side.name) to move").font(.bcRowTitle).foregroundStyle(BC.ink)
                Text(bits.joined(separator: " · "))
                    .font(.bcCaption).foregroundStyle(BC.mute).lineLimit(1).minimumScaleFactor(0.85)
            }
            Spacer(minLength: 0)
            if puzzle.cls != .book && !puzzle.isChallenge { ClassBadge(cls: puzzle.cls, size: 26) }
        }
    }

    // MARK: Card

    private var tone: Color {
        guard gameAt == nil else { return BC.line }
        switch status {
        case .solved: return BC.mint
        case .wrong: return BC.coral
        default: return BC.line
        }
    }

    private var label: (String, Color) {
        if gameAt != nil { return ("Your game", BC.mute) }
        switch status {
        case .solving: return (puzzle.isChallenge ? "Find the best move" : "Find better", puzzle.isChallenge ? BC.blue : BC.coral)
        case .checking: return ("Checking", BC.violet)
        case .wrong: return ("Not that one", BC.coral)
        case .solved: return (graded && hinted ? "Solved with a hint" : "Solved", BC.mint)
        case .revealed: return ("Best move", BC.mint)
        }
    }

    private var prompt: String {
        if let k = gameAt { return gameText(k) }
        if !note.isEmpty { return note }
        switch puzzle.kind {
        case .fix where puzzle.cls == .book:
            return "You played \(puzzle.playedText) and left your prep. Find your repertoire move."
        case .fix:
            return "You played \(puzzle.playedText), \(puzzle.cls.phrase). Find better."
        case .punish:
            if let lastText { return "\(puzzle.opponent) played \(lastText)\(lastMark). Punish it." }
            return puzzle.prompt.isEmpty ? "Punish it." : puzzle.prompt
        default:
            return puzzle.prompt.isEmpty ? "Find the best move." : puzzle.prompt
        }
    }

    /// "Chingx played 12…Nf6." for the game position after `k` plies.
    private func gameText(_ k: Int) -> String {
        guard k > 0, k <= history.count else { return history.isEmpty ? "Before your move." : "Start of the game." }
        let before = fen(at: k - 1)
        let move = Chess.numbered(history[k - 1].san, fenBefore: before)
        return Chess.sideToMove(before) == userColor ? "You played \(move)." : "\(puzzle.opponent) played \(move)."
    }

    private var card: some View {
        CardBox(padding: 14, radius: BC.rRow, border: tone == BC.line ? BC.line : tone.opacity(0.45)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    LabelText(label.0, colour: label.1)
                    Spacer(minLength: 0)
                    if let k = gameAt, !history.isEmpty {
                        Text("\(k) / \(history.count)")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(BC.faint)
                    }
                }
                Text(prompt).font(.system(size: 16, weight: .semibold)).foregroundStyle(BC.ink)
                    .lineLimit(2).minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, minHeight: 42, maxHeight: 42, alignment: .topLeading)
                    .contentTransition(.opacity)
                actions.frame(height: 38)
            }
        }
        .animation(BC.curve(0.3), value: status)
    }

    @ViewBuilder
    private var actions: some View {
        if gameAt != nil {
            HStack(spacing: 8) {
                Button { backToPuzzle() } label: { Label("Back to puzzle", systemImage: "arrow.uturn.forward") }
                    .buttonStyle(PillButton())
                Spacer(minLength: 0)
            }
        } else {
            switch status {
            case .solving, .wrong, .checking:
                HStack(spacing: 8) {
                    Button { hint() } label: { Label("Hint", systemImage: "lightbulb") }
                        .buttonStyle(PillButton())
                        .disabled(status == .checking)
                    Button { reveal() } label: { Label("Best move", systemImage: "star") }
                        .buttonStyle(PillButton())
                        .disabled(status == .checking)
                    Spacer(minLength: 0)
                    if status == .checking { ProgressView().tint(BC.mute).controlSize(.small) }
                }
            case .solved, .revealed:
                if !linePlies.isEmpty { lineStrip }
                else if puzzle.bestLine.count > 1 {
                    HStack {
                        Button { showLine() } label: { Label("Show the line", systemImage: "list.number") }
                            .buttonStyle(PillButton())
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    /// Stockfish's line as chips; the one shown is lit. Tap one to jump there.
    private var lineStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 5) {
                    ForEach(0..<linePlies.count, id: \.self) { k in
                        let on = lineAt == k + 1
                        Button {
                            guard lineAt != k + 1 else { return }
                            lineAt = k + 1
                            Feel.move(san: linePlies[k].san)
                            render()
                        } label: {
                            Text(lineChip(k))
                                .font(.system(size: 14, weight: on ? .bold : .semibold))
                                .foregroundStyle(on ? .black : (k < lineAt ? BC.ink : BC.mute))
                                .padding(.horizontal, 9).frame(height: 30)
                                .background(on ? BC.mint : BC.raised, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .id(k)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .onChange(of: lineAt) { _, i in
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(max(0, i - 1), anchor: .center) }
            }
        }
    }

    private func lineChip(_ k: Int) -> String {
        Chess.numbered(linePlies[k].san, fenBefore: k == 0 ? puzzle.fen : linePlies[k - 1].fenAfter)
    }

    // MARK: Bottom bar

    /// Back a move · forward a move · Analyse · Next.
    private var bar: some View {
        HStack(spacing: 8) {
            control("chevron.left", "Back a move", enabled: canBack, back)
            control("chevron.right", "Forward a move", enabled: canForward, forward)
            Spacer(minLength: 4)
            Button {
                Feel.tick()
                analyse()
            } label: { Label("Analyse", systemImage: "cpu") }
                .buttonStyle(PillButton())
            if status == .solved || status == .revealed {
                Button {
                    Feel.tap()
                    onNext()
                } label: {
                    HStack(spacing: 6) {
                        Text(isLast ? "Finish" : "Next")
                        Image(systemName: isLast ? "checkmark" : "arrow.right")
                    }
                }
                .buttonStyle(PillButton(filled: true))
                .transition(.opacity)
            }
        }
        .frame(height: 44)
    }

    private func control(_ icon: String, _ label: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 15, weight: .bold)).foregroundStyle(BC.ink)
                .frame(width: 44, height: 44)
                .background(BC.card, in: Circle())
                .overlay(Circle().stroke(BC.line, lineWidth: 1))
        }
        .buttonStyle(PressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .accessibilityLabel(label)
    }

    // MARK: Positions

    /// The game position after `k` plies (`history.count` is the puzzle position).
    private func fen(at k: Int) -> String {
        k <= 0 ? base : history[min(k, history.count) - 1].fenAfter
    }

    private func pair(_ p: Ply?) -> MovePair? { p.map { MovePair(from: $0.from, to: $0.to) } }

    /// After you've solved it the live board shows your move, so the puzzle position before it is one more
    /// step back. With the line loaded, the line's start is that position.
    private var liveShowsMove: Bool { linePlies.isEmpty && status == .solved && liveMove != nil }
    /// How many game steps sit before the live board / line.
    private var gameSteps: Int { history.count + (liveShowsMove ? 1 : 0) }

    private var canBack: Bool {
        guard status != .checking else { return false }
        if let k = gameAt { return k > 0 }
        if !linePlies.isEmpty && lineAt > 0 { return true }
        return gameSteps > 0
    }

    private var canForward: Bool {
        guard status != .checking else { return false }
        if gameAt != nil { return true }
        return !linePlies.isEmpty && lineAt < linePlies.count
    }

    private func back() {
        guard canBack else { return }
        if let k = gameAt { gameAt = k - 1 }
        else if !linePlies.isEmpty && lineAt > 0 { lineAt -= 1 }
        else { gameAt = gameSteps - 1 }
        Feel.tick()
        render()
    }

    private func forward() {
        guard canForward else { return }
        if let k = gameAt {
            let san = k < history.count ? history[k].san : (liveMove?.san ?? "")
            gameAt = k + 1 < gameSteps ? k + 1 : nil
            Feel.move(san: san)
        } else {
            lineAt += 1
            Feel.move(san: linePlies[lineAt - 1].san)
        }
        render()
    }

    private func backToPuzzle() {
        Feel.tick()
        gameAt = nil
        render()
    }

    /// Draws whatever the state says the board shows.
    private func render(animated: Bool = true) {
        if let k = gameAt {
            board.userColor = nil
            board.clearMarks()
            board.set(fen: fen(at: k), lastMove: k == 0 ? nil : pair(history[k - 1]), animated: animated)
        } else if !linePlies.isEmpty {
            board.userColor = nil
            board.clearMarks()
            let k = min(lineAt, linePlies.count)
            board.set(fen: k == 0 ? puzzle.fen : linePlies[k - 1].fenAfter,
                      lastMove: k == 0 ? pair(history.last) : pair(linePlies[k - 1]), animated: animated)
            if k < linePlies.count {
                board.arrows = [BoardArrow(from: linePlies[k].from, to: linePlies[k].to, colour: BC.mint, opacity: 0.7)]
            }
        } else {
            showLive(animated: animated)
        }
    }

    /// The puzzle as you left it.
    private func showLive(animated: Bool = true) {
        board.clearMarks()
        switch status {
        case .checking, .solved:
            if let m = liveMove {
                board.userColor = nil
                board.set(fen: m.fenAfter, lastMove: pair(m), animated: animated)
                if status == .solved { markSolved(m) }
                return
            }
            board.userColor = nil
            board.set(fen: puzzle.fen, lastMove: pair(history.last), animated: animated)
        case .revealed:
            board.userColor = nil
            board.set(fen: puzzle.fen, lastMove: pair(history.last), animated: animated)
            if let b = puzzle.bestMove { board.arrows = [BoardArrow(from: b.from, to: b.to, colour: BC.mint, opacity: 0.7)] }
        case .solving, .wrong:
            liveMove = nil
            board.set(fen: puzzle.fen, lastMove: pair(history.last), animated: animated)
            showPlayedArrow()
            if hinted, let b = puzzle.bestMove { board.tints = [b.from: .hint] }
            board.userColor = puzzle.side
        }
    }

    private func analyse() {
        var moves: [String]
        if let k = gameAt {
            moves = history.prefix(k).map(\.uci)
        } else if !linePlies.isEmpty {
            moves = history.map(\.uci) + linePlies.prefix(lineAt).map(\.uci)
        } else {
            moves = history.map(\.uci)
            if let m = liveMove, board.fen == m.fenAfter { moves.append(m.uci) }
        }
        let title = "vs \(puzzle.opponent)"
        if let game = store.game(puzzle.gameID), !base.isEmpty, base == game.startFEN {
            app.open(.board(BoardStart(fen: game.startFEN, history: moves, title: title, flipped: game.userColor == .black)))
        } else {
            // No game to go with it: start from the puzzle.
            app.open(.board(BoardStart(fen: puzzle.fen, history: moves, title: title, flipped: board.flipped)))
        }
    }

    // MARK: Actions

    private func setUp() {
        guard !ready else { return }
        ready = true
        loadGame()
        board.flipped = puzzle.side == .black
        board.showCoordinates = progress.settings.coordinates
        board.onMove = { from, to, promo in attempt(from: from, to: to, promo: promo) }
        showLive(animated: false)
    }

    /// The game's moves up to the puzzle, so the last move shows and you can step back through it.
    private func loadGame() {
        guard let game = store.game(puzzle.gameID), puzzle.ply > 0 else { base = puzzle.fen; return }
        let plies = Chess.replay(Array(game.ucis.prefix(puzzle.ply)), from: game.startFEN)
        // Only when it really leads to this puzzle.
        func key(_ f: String?) -> String { (f ?? "").split(separator: " ").prefix(4).joined(separator: " ") }
        guard plies.count == puzzle.ply, key(plies.last?.fenAfter) == key(puzzle.fen) else { base = puzzle.fen; return }
        base = game.startFEN
        history = plies
        userColor = game.userColor
        if let c = game.review?.classes[safe: puzzle.ply - 1], c == .blunder || c == .mistake { lastMark = c.symbol }
    }

    private func showPlayedArrow() {
        if let m = puzzle.playedMove, !puzzle.isChallenge {
            board.arrows = [BoardArrow(from: m.from, to: m.to, colour: BC.coral, opacity: 0.8)]
        }
    }

    private func grade(_ solved: Bool) {
        guard !graded else { return }
        graded = true
        progress.recordPuzzle(puzzle.progressID, solved: solved)
        Pro.shared.use(.positions)
        DailySet.markTried(puzzle.progressID)
        onResult(solved)
    }

    private func hint() {
        guard let b = puzzle.bestMove else { return }
        hinted = true
        status = .solving
        note = "Move the highlighted piece."
        if gameAt != nil || board.fen != puzzle.fen {
            gameAt = nil
            render()
        }
        board.tints = [b.from: .hint]
        Feel.tap()
    }

    private func reveal() {
        guard let b = puzzle.bestPly else { return }
        checkTask?.cancel()
        grade(false)
        status = .revealed
        liveMove = nil
        gameAt = nil
        note = "\(Chess.numbered(b.san, fenBefore: puzzle.fen)) was the move. Step through the line."
        Feel.wrong()
        loadLine(at: 0)
    }

    private func showLine() {
        Feel.tick()
        // If you played Stockfish's move it's already on the board: start the line after it.
        let first = Chess.play(puzzle.bestLine.first ?? puzzle.best, on: puzzle.fen)
        loadLine(at: liveMove != nil && liveMove?.uci == first?.uci ? 1 : 0)
    }

    private func loadLine(at k: Int) {
        linePlies = Chess.replay(puzzle.bestLine.isEmpty ? [puzzle.best] : puzzle.bestLine, from: puzzle.fen)
        lineAt = min(k, linePlies.count)
        gameAt = nil
        render()
    }

    private func attempt(from: String, to: String, promo: Piece.Kind?) {
        guard gameAt == nil, linePlies.isEmpty, status == .solving || status == .wrong,
              let ply = Chess.move(from: from, to: to, promotion: promo, on: puzzle.fen) else { return }
        liveMove = ply
        board.set(fen: ply.fenAfter, lastMove: MovePair(from: from, to: to))
        Feel.move(san: ply.san)
        board.clearMarks()
        board.userColor = nil
        if ply.uci == puzzle.best || ply.uci.prefix(4) == puzzle.best.prefix(4) && puzzle.best.count == 4 {
            solved(ply, exact: true); return
        }
        if case .checkmate = Chess.outcome(ply.fenAfter) { solved(ply, exact: false); return }
        if puzzle.kind == .fix && puzzle.cls == .book {
            wrong(ply, why: "\(ply.san) isn't your repertoire move.")
            return
        }
        status = .checking
        note = "Checking \(ply.san)…"
        let side = puzzle.side
        let fen = puzzle.fen
        checkTask?.cancel()
        checkTask = Task { @MainActor in
            let engine = EngineService.shared
            let before = await engine.analyse(fen: fen, depth: 14, owner: Self.owner).first
            if Task.isCancelled { return }
            let after = await engine.analyse(fen: ply.fenAfter, depth: 14, owner: Self.owner).first
            if Task.isCancelled { return }
            guard status == .checking, liveMove == ply else { return }
            // The engine not answering isn't your mistake: don't grade it.
            guard let before, let after else { couldNotCheck(); return }
            let loss = Eval.points(before, for: side) - Eval.points(after, for: side)
            if loss < 0.05 { solved(ply, exact: false) }
            else { wrong(ply, why: "\(ply.san) gives too much away.") }
        }
    }

    /// Back to the position, ungraded.
    private func couldNotCheck() {
        status = .solving
        note = "Couldn't check that — try again."
        gameAt = nil
        render()
    }

    private func markSolved(_ ply: Ply) {
        board.tints = [ply.to: .right]
        board.badge = BoardBadge(square: ply.to, cls: exact ? .best : .excellent)
    }

    private func solved(_ ply: Ply, exact: Bool) {
        grade(!hinted)
        Feel.right()
        status = .solved
        liveMove = ply
        self.exact = exact
        markSolved(ply)
        let best = puzzle.bestPly?.san ?? ""
        note = exact ? "\(ply.san). Exactly Stockfish's move." : "\(ply.san) works too. Stockfish's first choice was \(best)."
    }

    private func wrong(_ ply: Ply, why: String) {
        grade(false)
        Feel.wrong()
        status = .wrong
        board.tints = [ply.to: .wrong]
        note = why + " Try again."
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 750_000_000)
            // Only if the wrong try is still what's on the board (you may have stepped away or tried again).
            guard status == .wrong, gameAt == nil, linePlies.isEmpty, liveMove == ply, board.fen == ply.fenAfter else { return }
            showLive()
        }
    }
}
