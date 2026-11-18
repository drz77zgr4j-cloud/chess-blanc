import SwiftUI
import ChessKit

/// One practice session: builds the lines to play from the request, then runs them move by move.
/// No engine calls in here: everything the board needs is already in the repertoire.
@MainActor
final class PracticeSession: ObservableObject {
    /// What one of your moves is in this line.
    enum Kind { case graded, learn, known, fresh }
    enum Outcome { case pending, clean, slipped, skipped }
    enum Phase { case playing, empty, summary }
    enum Pass { case first, recall }
    enum Tone { case neutral, right, wrong, learn, done }

    struct Line: Identifiable {
        let id: Int
        let rep: Repertoire
        let steps: [RepNode]
        let start: Int                    // index of the first trained move; everything before is context
        let kinds: [Int: Kind]            // your moves from `start` on
        var learnCount: Int { kinds.values.filter { $0 == .learn }.count }
        var title: String { steps.last.map { rep.title(for: $0) } ?? rep.name }
    }

    // What the screen shows
    @Published private(set) var phase: Phase = .playing
    @Published private(set) var lines: [Line] = []
    @Published private(set) var outcomes: [Outcome] = []
    @Published private(set) var current = 0
    @Published private(set) var board = BoardState()
    @Published private(set) var headline = ""
    @Published private(set) var detail = ""
    @Published private(set) var tone: Tone = .neutral
    @Published private(set) var tag: (text: String, colour: Color)? = nil
    @Published private(set) var waiting = false            // the user's turn
    @Published private(set) var pass: Pass = .first
    /// The line is finished and waits for Next (or Analyse, or a step back through it).
    @Published private(set) var lineDone = false
    /// New lines were wanted but today's free allowance is used up.
    @Published private(set) var limitReached = false
    /// Browsing the line: the ply shown (0 = the start). Nil is the live position.
    @Published private(set) var viewPly: Int? = nil
    private var liveArrows: [BoardArrow] = []
    private var liveTints: [String: SquareTint] = [:]
    /// What the current queue was built for (the empty state can rebuild it as `.learn`).
    @Published private(set) var mode: PracticeRequest.Mode

    // Summary
    @Published private(set) var rightFirst = 0
    @Published private(set) var tries = 0
    @Published private(set) var newlyLearned = 0
    private(set) var coverageBefore: [String: Double] = [:]
    private(set) var reps: [Repertoire] = []

    let request: PracticeRequest
    private let progress: ProgressStore
    private var index = 0
    private var misses = 0
    private var fen = Chess.startFEN
    private var expected: Ply?
    private var slipped = false
    private var recallClean = true
    private var recallFails = 0                            // failed "from memory" runs of the current line
    private var graded: Set<String> = []
    private var counted: Set<String> = []                  // recall moves already in the first-try score
    private var task: Task<Void, Never>?

    init(request: PracticeRequest, reps all: [Repertoire], progress: ProgressStore) {
        self.request = request
        self.progress = progress
        self.mode = request.mode
        reps = Self.scoped(all, request)
        build(mode: request.mode)
    }

    var line: Line? { lines.indices.contains(current) ? lines[current] : nil }
    var expectedNode: RepNode? { line.flatMap { $0.steps.indices.contains(index) ? $0.steps[index] : nil } }
    var currentFEN: String { fen }
    /// The move "Why?" explains: the one you're on, or the last one you played.
    var whyNode: RepNode? {
        guard let line else { return nil }
        if waiting { return expectedNode }
        return line.steps.prefix(index).last { $0.mover == line.rep.color }
    }
    var whyFEN: String? { whyNode?.fenBefore }
    /// Has anything in these openings been learned yet (so there's something to revise)?
    var knowsAnything: Bool {
        let under = request.nodeID ?? ""
        return reps.contains { rep in rep.myMoves(under: under).contains { progress.memory(rep, $0).level > 0 } }
    }

    var canLearnMore: Bool {
        let under = request.nodeID ?? ""
        return reps.contains { rep in rep.myMoves(under: under).contains { progress.memory(rep, $0).level == 0 } }
    }

    // MARK: Planning (shared with Today)

    /// The new-move cap for "every move under here" (`.all`): the user picked the branch on purpose.
    private static let allModeNewCap = 30

    /// The repertoires a request covers, White first.
    static func scoped(_ all: [Repertoire], _ request: PracticeRequest) -> [Repertoire] {
        if let id = request.repID { return all.filter { $0.id == id } }
        if let ids = request.repIDs { return all.filter { ids.contains($0.id) } }
        return all.sorted { $0.color == .white && $1.color == .black }
    }

    /// What a session for `request` holds: moves due for review and new moves it will teach.
    /// Today's card and the session both use this, so their numbers agree. `newMovesPerDay` is respected
    /// (0 means no new moves) except when the user explicitly chose to learn (`.learn`): then at least 3.
    static func plan(reps: [Repertoire], progress: ProgressStore, request: PracticeRequest) -> (due: Int, new: Int) {
        let b = budgets(reps: scoped(reps, request), progress: progress, request: request)
        return (b.due, b.new.values.reduce(0, +))
    }

    /// Due count and the new-move budget per repertoire id, shared out evenly (never more than a repertoire has).
    private static func budgets(reps: [Repertoire], progress: ProgressStore, request: PracticeRequest) -> (due: Int, new: [String: Int]) {
        let under = request.nodeID ?? ""
        let now = Date()
        var due = 0
        var fresh: [String: Int] = [:]
        for rep in reps {
            let depth = StudyDepth.of(rep.id).minReach
            for n in rep.myMoves(under: under) {
                let m = progress.memory(rep, n)
                if m.level == 0 { if n.reach >= depth || !under.isEmpty { fresh[rep.id, default: 0] += 1 } }
                else if (m.due ?? .distantPast) <= now { due += 1 }
            }
        }
        let leftToday = max(0, progress.settings.newMovesPerDay - progress.newLearnedToday)
        let total: Int
        switch request.mode {
        case .review, .revise: total = 0
        case .learn: total = 12; due = 0           // you asked to learn: not held back by the daily number
        case .mixed: total = leftToday
        case .all: total = allModeNewCap
        case .session: total = 12
        }
        var out: [String: Int] = [:]
        var left = total
        var gave = true
        while left > 0 && gave {
            gave = false
            for rep in reps where left > 0 && out[rep.id, default: 0] < fresh[rep.id, default: 0] {
                out[rep.id, default: 0] += 1
                left -= 1
                gave = true
            }
        }
        return (due, out)
    }

    // MARK: Building the queue

    func build(mode: PracticeRequest.Mode) {
        task?.cancel()
        self.mode = mode
        var req = request
        req.mode = mode
        let budget = Self.budgets(reps: reps, progress: progress, request: req).new
        var built: [[Line]] = []        // per repertoire: reviews (or everything, for .all)
        var learnBuilt: [[Line]] = []   // per repertoire: new moves
        var reviseBuilt: [[Line]] = []  // per repertoire: learned moves, for a session's top-up
        let under = request.nodeID ?? ""
        for rep in reps {
            let pool = rep.myMoves(under: under)
            let due = pool.filter { progress.isDue(rep, $0) }
            // New moves come from the chosen depth (main lines first), unless you picked a branch yourself.
            let depth = under.isEmpty ? StudyDepth.of(rep.id).minReach : 0
            let fresh = progress.prioritised(rep, pool.filter { progress.memory(rep, $0).level == 0 && $0.reach >= depth })
            let b = budget[rep.id] ?? 0
            switch mode {
            case .review:
                built.append(makeLines(rep, targets: due, fresh: [], budget: 0, maxLines: 14))
            case .learn:
                learnBuilt.append(makeLines(rep, targets: [], fresh: fresh, budget: b, maxLines: max(1, b)))
            case .mixed:
                // Reviews first, then today's new moves (the planner's number, so Today and the session agree).
                built.append(makeLines(rep, targets: due, fresh: [], budget: 0, maxLines: 14))
                if b > 0 { learnBuilt.append(makeLines(rep, targets: [], fresh: fresh, budget: b, maxLines: b)) }
            case .all:
                // Everything under the position, new and known together.
                let known = pool.filter { progress.memory(rep, $0).level > 0 && !progress.isDue(rep, $0) }
                built.append(makeLines(rep, targets: due + known, fresh: fresh, budget: b, maxLines: 10))
            case .revise:
                let known = pool.filter { progress.memory(rep, $0).level > 0 }
                built.append(makeLines(rep, targets: known, fresh: [], budget: 0, maxLines: 15, random: true))
            case .session:
                built.append(makeLines(rep, targets: due, fresh: [], budget: 0, maxLines: 10))
                if b > 0 { learnBuilt.append(makeLines(rep, targets: [], fresh: fresh, budget: b, maxLines: b)) }
                let known = pool.filter { progress.memory(rep, $0).level > 0 && !progress.isDue(rep, $0) }
                reviseBuilt.append(makeLines(rep, targets: known, fresh: [], budget: 0, maxLines: 10, random: true))
            }
        }
        // New lines: as many as today's allowance has left (Pro: all of them).
        let allLearn = interleave(learnBuilt)
        let room = Pro.shared.left(.newLines)
        let learnLines = Array(allLearn.prefix(room))
        limitReached = learnLines.count < allLearn.count
        // Reviews are capped; the new moves always fit after them. A session tops up with revision to about 20 lines.
        var ordered = Array(interleave(built).prefix(mode == .all ? 10 : mode == .revise ? 15 : 20)) + learnLines
        if mode == .revise { ordered.shuffle() }
        if mode == .session {
            let room = max(0, 20 - ordered.count)
            ordered += interleave(reviseBuilt).prefix(room)
        }
        lines = ordered.enumerated().map { i, l in
            Line(id: i, rep: l.rep, steps: l.steps, start: l.start, kinds: l.kinds)
        }
        outcomes = Array(repeating: .pending, count: lines.count)
        coverageBefore = Dictionary(uniqueKeysWithValues: reps.map { ($0.id, progress.coverage($0)) })
        rightFirst = 0; tries = 0; newlyLearned = 0
        graded = []
        counted = []
        current = 0
        phase = lines.isEmpty ? .empty : .playing
    }

    private func interleave(_ groups: [[Line]]) -> [Line] {
        var out: [Line] = []
        let n = groups.map(\.count).max() ?? 0
        for i in 0..<n { for g in groups where i < g.count { out.append(g[i]) } }
        return out
    }

    /// Groups moves into lines from the start position down, so one played line covers several moves.
    /// `targets` are moves to review; `fresh` are new moves that may be learned, up to `budget` of them,
    /// in chunks of at most 5 along one line (the most common way the game goes).
    private func makeLines(_ rep: Repertoire, targets: [RepNode], fresh: [RepNode], budget: Int, maxLines: Int,
                           random: Bool = false) -> [Line] {
        var open = Set(targets.map(\.id))
        var freshOpen = Set(budget > 0 ? fresh.map(\.id) : [])
        var left = budget
        // Revision picks its moves at random (weighted towards common positions); everything else goes most common first.
        let order = random
            ? targets.map { ($0, Double.random(in: 0..<1) * (0.3 + min(1, $0.reach * 20))) }.sorted { $0.1 > $1.1 }.map(\.0)
            : (targets + (budget > 0 ? fresh : [])).sorted { $0.reach > $1.reach }
        var out: [Line] = []
        func wanted(_ id: String) -> Bool { open.contains(id) || (left > 0 && freshOpen.contains(id)) }

        // Work below each node, computed once: every target adds 1 to each of its ancestors (and itself).
        // "Is anything left under this reply?" is then a lookup instead of a scan of every path.
        var ancestors: [String: [String]] = [:]
        func ancestorIDs(_ id: String) -> [String] {
            if let a = ancestors[id] { return a }
            var ids: [String] = []
            var i = id.startIndex
            while let comma = id[i...].firstIndex(of: ",") {
                ids.append(String(id[..<comma]))
                i = id.index(after: comma)
            }
            ids.append(id)
            ancestors[id] = ids
            return ids
        }
        var openBelow: [String: Int] = [:]
        var freshBelow: [String: Int] = [:]
        for id in open { for a in ancestorIDs(id) { openBelow[a, default: 0] += 1 } }
        for id in freshOpen { for a in ancestorIDs(id) { freshBelow[a, default: 0] += 1 } }
        func closeOpen(_ id: String) {
            guard open.remove(id) != nil else { return }
            for a in ancestorIDs(id) { openBelow[a, default: 0] -= 1 }
        }
        func closeFresh(_ id: String) {
            guard freshOpen.remove(id) != nil else { return }
            for a in ancestorIDs(id) { freshBelow[a, default: 0] -= 1 }
        }
        func workBelow(_ id: String) -> Bool {
            (openBelow[id] ?? 0) > 0 || (left > 0 && (freshBelow[id] ?? 0) > 0)
        }

        for t in order {
            guard out.count < maxLines else { break }
            guard wanted(t.id) else { continue }
            var steps = t.path
            var cur = t
            // Walk down: your move, or the most common reply whose subtree still has work to do.
            while steps.count < 40 {
                let c = rep.continuing(cur)
                guard !c.children.isEmpty else { break }
                let next: RepNode
                if let mine = c.children.first(where: { $0.mover == rep.color }) {
                    next = mine
                } else {
                    let live = c.children.filter { kid in
                        let root = rep.continuing(kid).id
                        return workBelow(kid.id) || (root != kid.id && workBelow(root))
                    }
                    // Revision lets the opponent vary (weighted by how often each reply is played).
                    guard let pick = random ? Self.weighted(live) : live.max(by: { $0.share < $1.share }) else { break }
                    next = pick
                }
                steps.append(next)
                cur = next
            }
            // Kinds and the trained span: from the first target to the last one.
            var kinds: [Int: Kind] = [:]
            var first: Int?
            var last: Int?
            var learnCount = 0
            for (i, s) in steps.enumerated() where s.mover == rep.color {
                let k: Kind
                var target = false
                if open.contains(s.id) {
                    k = progress.isDue(rep, s) ? .graded : .known
                    target = true
                } else if freshOpen.contains(s.id) && left > 0 && learnCount < 5 {
                    k = .learn
                    learnCount += 1
                    left -= 1
                    target = true
                } else {
                    k = progress.memory(rep, s).level == 0 ? .fresh : .known
                }
                kinds[i] = k
                if target {
                    if first == nil { first = i }
                    last = i
                }
                if k == .learn && (learnCount >= 5 || left == 0) && open.isEmpty { break }
            }
            guard let start = first, let end = last else { continue }
            let trimmed = Array(steps.prefix(end + 1))
            var finalKinds: [Int: Kind] = [:]
            for (i, k) in kinds where i >= start && i <= end { finalKinds[i] = k }
            for (i, s) in trimmed.enumerated() where i >= start {
                closeOpen(s.id)
                if finalKinds[i] == .learn { closeFresh(s.id) }
            }
            out.append(Line(id: out.count, rep: rep, steps: trimmed, start: start, kinds: finalKinds))
        }
        return out
    }

    private static func weighted(_ nodes: [RepNode]) -> RepNode? {
        let total = nodes.reduce(0) { $0 + max(0.02, $1.share) }
        var r = Double.random(in: 0..<max(0.0001, total))
        for n in nodes { r -= max(0.02, n.share); if r < 0 { return n } }
        return nodes.last
    }

    /// Another batch in the same spirit, for "Keep going" at the end. Nothing left in this mode? Revise instead.
    func keepGoing() {
        let m: PracticeRequest.Mode = (mode == .review || mode == .mixed) ? .session : mode
        build(mode: m)
        if lines.isEmpty { build(mode: .revise) }
        guard !lines.isEmpty else { return }
        withAnimation(BC.curve(0.4)) { phase = .playing }
        begin()
    }

    // MARK: Running

    func begin() {
        guard phase == .playing, !lines.isEmpty else { return }
        startLine(0, pass: .first, slide: false)
    }

    func stop() {
        stopped = task != nil
        task?.cancel()
        task = nil
    }

    /// Back on screen (after Analyse or "Why?"): whatever was mid-way (the opponent's reply, the replay
    /// before "Now from memory", saving a finished line) picks up again, so the board never freezes.
    func resume() {
        guard stopped else { return }
        stopped = false
        guard phase == .playing, !waiting, !lineDone, let line, lines.indices.contains(current) else { return }
        if index >= line.steps.count {
            run { [weak self] in await self?.lineFinished() }
        } else if index < line.start || pass == .recall && index == line.start {
            startLine(current, pass: pass, slide: false)
        } else {
            run { [weak self] in await self?.advance() }
        }
    }
    private var stopped = false

    private func startLine(_ i: Int, pass: Pass, slide: Bool) {
        task?.cancel()
        guard lines.indices.contains(i) else { finish(); return }
        let line = lines[i]
        if pass == .first {
            let b = BoardState()
            b.flipped = line.rep.color == .black
            b.showCoordinates = progress.settings.coordinates
            b.userColor = nil
            b.onMove = { [weak self] from, to, promo in self?.userMove(from: from, to: to, promotion: promo) }
            if slide {
                withAnimation(BC.curve(0.45)) { current = i; board = b }
            } else {
                current = i
                board = b
            }
            slipped = false
            recallFails = 0
        }
        self.pass = pass
        recallClean = true
        waiting = false
        lineDone = false
        viewPly = nil
        index = 0
        misses = 0
        fen = Chess.startFEN
        board.clearMarks()
        if pass == .recall {
            // Rewind: pieces slide back to the start of the chunk.
            let contextFEN = line.start > 0 ? line.steps[line.start - 1].fenAfter : Chess.startFEN
            fen = contextFEN
            index = line.start
            let lm = line.start > 0 ? line.steps[line.start - 1].move : nil
            board.set(fen: contextFEN, lastMove: lm)
            say("From memory", line.learnCount > 1 ? "Play the line again. No arrows this time." : "Play it again. No arrow this time.",
                tone: .learn, tag: ("Recall", BC.blue))
            run { [weak self] in
                try await Task.sleep(nanoseconds: 700_000_000)
                await self?.advance()
            }
            return
        }
        board.set(fen: Chess.startFEN, lastMove: nil, animated: false)
        say(line.title, line.start > 0 ? "Setting up the position…" : "From the first move.", tone: .neutral,
            tag: (line.rep.color == .white ? "White" : "Black", BC.mute))
        run { [weak self] in
            try await Task.sleep(nanoseconds: slide ? 450_000_000 : 250_000_000)
            // Fast-forward the context.
            for k in 0..<line.start {
                guard let self else { return }
                try await Task.sleep(nanoseconds: 250_000_000)
                guard self.playStep(k) else { self.abandonLine(); return }
            }
            await self?.advance()
        }
    }

    private func run(_ body: @escaping @MainActor () async throws -> Void) {
        task?.cancel()
        task = Task { @MainActor in
            do { try await body() } catch {}
        }
    }

    /// Plays the line's move `k` on the board. False when it can't be played (bad data).
    @discardableResult
    private func playStep(_ k: Int) -> Bool {
        guard let line, line.steps.indices.contains(k) else { return false }
        let n = line.steps[k]
        guard let p = Chess.play(n.uci, on: fen) else { return false }
        fen = p.fenAfter
        board.set(fen: fen, lastMove: MovePair(from: p.from, to: p.to))
        Feel.move(san: p.san)
        index = k + 1
        return true
    }

    /// A line whose moves don't play out on the board: skip to the next one instead of waiting forever.
    private func abandonLine() {
        guard phase == .playing, lines.indices.contains(current) else { return }
        waiting = false
        board.userColor = nil
        outcomes[current] = .skipped
        next()
    }

    private func advance() async {
        guard let line else { return }
        while index < line.steps.count {
            let n = line.steps[index]
            if n.mover == line.rep.color {
                awaitUser()
                return
            }
            do { try await Task.sleep(nanoseconds: 400_000_000) } catch { return }
            if Task.isCancelled { return }
            board.clearMarks()
            guard playStep(index) else { abandonLine(); return }
        }
        await lineFinished()
    }

    private func kind(_ i: Int) -> Kind {
        guard let line else { return .known }
        return line.kinds[i] ?? .known
    }

    private func awaitUser() {
        guard let line, let n = expectedNode else { return }
        guard let exp = Chess.play(n.uci, on: fen) else { abandonLine(); return }
        expected = exp
        misses = 0
        board.userColor = line.rep.color
        waiting = true
        let k = kind(index)
        let shownHelp = (k == .learn && pass == .first) || k == .fresh
        if shownHelp {
            board.arrows = [BoardArrow(from: n.from, to: n.to, colour: BC.arrow, opacity: 0.85)]
            say("New move · \(n.numbered)", n.whyLine, tone: .learn, tag: ("New", BC.blue))
        } else if pass == .recall {
            say("Your move", "From memory: what comes next?", tone: .learn, tag: ("Recall", BC.blue))
        } else if k == .graded && !graded.contains(key(line.rep, n)) {
            say("Your move", "What do you play here?", tone: .neutral, tag: ("Review", BC.mute))
        } else {
            say("Your move", "Keep going. You know this one.", tone: .neutral, tag: nil)
        }
    }

    private func key(_ rep: Repertoire, _ n: RepNode) -> String { rep.id + "|" + n.id }

    func userMove(from: String, to: String, promotion: Piece.Kind?) {
        guard waiting, let line, let n = expectedNode, let exp = expected,
              let ply = Chess.move(from: from, to: to, promotion: promotion, on: fen) else { return }
        let k = kind(index)
        let gradeKey = key(line.rep, n)
        if Chess.placementKey(ply.fenAfter) == Chess.placementKey(exp.fenAfter) {
            // Right.
            waiting = false
            board.userColor = nil
            board.clearMarks()
            fen = exp.fenAfter
            board.set(fen: fen, lastMove: MovePair(from: exp.from, to: exp.to))
            board.tints = [exp.to: .right]
            Feel.move(san: exp.san)
            let firstTry = misses == 0
            switch k {
            case .graded where !graded.contains(gradeKey):
                graded.insert(gradeKey)
                progress.answer(line.rep, n, firstTryRight: firstTry)   // misses already recorded the wrong
                countTry(firstTry)
            case .known where !graded.contains(gradeKey) && pass == .first:
                // Symmetric with a miss: a right answer is recorded too (it keeps the schedule if not due).
                graded.insert(gradeKey)
                progress.answer(line.rep, n, firstTryRight: firstTry)
                countTry(firstTry)
            case .learn where pass == .recall:
                // Once per session: retries and "Once more" runs don't count again.
                if counted.insert(gradeKey).inserted { countTry(firstTry) }
            default:
                break
            }
            if firstTry && !(k == .learn && pass == .first) && k != .fresh { Feel.right() } else { Feel.tap() }
            say(firstTry ? "Right · \(n.numbered)" : "That's it · \(n.numbered)",
                firstTry ? (k == .learn && pass == .first ? "Nice. Keep following the line." : "Well remembered.") : "Now you have it.",
                tone: .right, tag: nil)
            index += 1
            misses = 0
            run { [weak self] in await self?.advance() }
            return
        }
        // Wrong.
        let wrongFirst = misses == 0
        misses += 1
        if wrongFirst {
            switch k {
            case .graded where !graded.contains(gradeKey) && pass == .first:
                // Record the miss now; the retry is never graded again.
                graded.insert(gradeKey)
                progress.answer(line.rep, n, firstTryRight: false)
                countTry(false)
                slipped = true
            case .known where !graded.contains(gradeKey) && pass == .first:
                graded.insert(gradeKey)
                progress.answer(line.rep, n, firstTryRight: false)
                countTry(false)
                slipped = true
            case .learn where pass == .recall:
                recallClean = false
                if counted.insert(gradeKey).inserted { countTry(false) }
            default:
                if pass == .recall { recallClean = false }
                if k == .known || k == .graded { slipped = true }
            }
        }
        waiting = false
        board.userColor = nil
        board.arrows = []
        board.set(fen: ply.fenAfter, lastMove: MovePair(from: ply.from, to: ply.to))
        board.tints = [ply.to: .wrong]
        Feel.move(san: ply.san)
        Feel.wrong()
        let helped = (k == .learn && pass == .first) || k == .fresh
        if helped {
            say("Not that one", "Follow the arrow: \(n.san).", tone: .wrong, tag: nil)
        } else if misses == 1 {
            say("Not quite", "Try again. It's this piece.", tone: .wrong, tag: nil)
        } else {
            say("Not quite", "Follow the arrow: \(n.san).", tone: .wrong, tag: nil)
        }
        let before = fen
        let lastPair = line.steps.indices.contains(index - 1) && index > 0 ? line.steps[index - 1].move : nil
        run { [weak self] in
            try await Task.sleep(nanoseconds: 650_000_000)
            guard let self else { return }
            self.board.set(fen: before, lastMove: lastPair)
            self.board.tints = [:]
            if helped || self.misses >= 2 {
                self.board.arrows = [BoardArrow(from: n.from, to: n.to, colour: BC.arrow, opacity: 0.85)]
            }
            if !helped { self.board.tints = [n.from: .hint] }
            self.board.userColor = line.rep.color
            self.waiting = true
        }
    }

    private func countTry(_ right: Bool) {
        tries += 1
        if right { rightFirst += 1 }
    }

    private func lineFinished() async {
        guard let line else { return }
        waiting = false
        board.userColor = nil
        let hasLearn = line.learnCount > 0
        do {
            if hasLearn && pass == .first {
                try await Task.sleep(nanoseconds: 500_000_000)
                say("Now from memory", "Same moves, no help. Get it clean once and it's yours.", tone: .learn, tag: ("Recall", BC.blue))
                try await Task.sleep(nanoseconds: 1_300_000_000)
                startLine(current, pass: .recall, slide: false)
                return
            }
            if hasLearn && pass == .recall && !recallClean {
                recallFails += 1
                if recallFails < 2 {
                    try await Task.sleep(nanoseconds: 500_000_000)
                    say("Once more", "Nearly. One clean run and it's yours.", tone: .learn, tag: ("Recall", BC.blue))
                    try await Task.sleep(nanoseconds: 1_200_000_000)
                    startLine(current, pass: .recall, slide: false)
                    return
                }
                // Two misses in a row: keep it anyway and move on. The review in a few hours does the rest.
            }
            if hasLearn {
                var count = 0
                for (i, k) in line.kinds where k == .learn {
                    let n = line.steps[i]
                    if progress.memory(line.rep, n).level == 0 {
                        progress.learned(line.rep, n)
                        count += 1
                    }
                }
                newlyLearned += count
                if count > 0 { Pro.shared.use(.newLines) }
                Feel.gained()
                if recallClean {
                    say(count == 1 ? "Learned it" : "Learned all \(count)",
                        "It'll be checked again later, from a different angle.", tone: .done, tag: ("Learned", BC.mint))
                } else {
                    say("Saved — tricky one",
                        "It comes up again sooner until it sticks.", tone: .done, tag: ("Learned", BC.mint))
                }
            } else {
                say(slipped ? "Line done" : "Clean line", slipped ? "Slips come up again soon until they stick." : "Every move right.",
                    tone: slipped ? .neutral : .done, tag: nil)
                if !slipped { Feel.right() }
            }
        } catch { return }
        outcomes[current] = slipped ? .slipped : .clean
        withAnimation(BC.curve(0.3)) { lineDone = true }
    }

    // MARK: Moving around

    var isLastLine: Bool { current + 1 >= lines.count }
    /// Arrows and stepping work while it's your move or once the line is done, never mid-animation.
    var canBrowse: Bool { (waiting || lineDone) && index > 0 }
    var canStepBack: Bool { canBrowse && (viewPly ?? index) > 0 }
    var canStepForward: Bool { viewPly != nil }

    /// The line as played so far, to open on the analysis board.
    var analysisStart: BoardStart? {
        guard let line else { return nil }
        return BoardStart(fen: Chess.startFEN, history: line.steps.prefix(viewPly ?? index).map(\.uci),
                          title: line.title, flipped: line.rep.color == .black)
    }

    func stepBack() {
        guard canStepBack else { return }
        if viewPly == nil {
            liveArrows = board.arrows
            liveTints = board.tints
            board.userColor = nil
        }
        show(ply: (viewPly ?? index) - 1)
    }

    func stepForward() {
        guard let v = viewPly else { return }
        if v + 1 >= index { backToLive() } else { show(ply: v + 1) }
    }

    private func show(ply k: Int) {
        guard let line else { return }
        viewPly = k
        let f = k == 0 ? Chess.startFEN : line.steps[k - 1].fenAfter
        board.clearMarks()
        board.set(fen: f, lastMove: k > 0 ? line.steps[k - 1].move : nil)
        Feel.tick()
    }

    private func backToLive() {
        guard let line else { return }
        viewPly = nil
        board.set(fen: fen, lastMove: index > 0 ? line.steps[index - 1].move : nil)
        board.arrows = liveArrows
        board.tints = liveTints
        if waiting { board.userColor = line.rep.color }
        Feel.tick()
    }

    /// Next line (or the summary after the last one). Skips the line if it isn't done.
    func nextLine() {
        guard phase == .playing, lines.indices.contains(current) else { return }
        if !lineDone {
            task?.cancel()
            outcomes[current] = .skipped
        }
        next()
    }

    /// Back to the line before this one, from its first move.
    func previousLine() {
        guard phase == .playing, current > 0 else { return }
        task?.cancel()
        outcomes[current - 1] = .pending
        Feel.next()
        startLine(current - 1, pass: .first, slide: true)
    }

    func skipLine() {
        guard phase == .playing, lines.indices.contains(current) else { return }
        task?.cancel()
        outcomes[current] = .skipped
        next()
    }

    private func next() {
        if current + 1 < lines.count {
            Feel.next()
            startLine(current + 1, pass: .first, slide: true)
        } else {
            finish()
        }
    }

    private func finish() {
        task?.cancel()
        waiting = false
        withAnimation(BC.curve(0.45)) { phase = .summary }
        Feel.complete()
    }

    private func say(_ h: String, _ d: String, tone: Tone, tag: (String, Color)?) {
        withAnimation(BC.curve(0.22)) {
            headline = h
            detail = d
            self.tone = tone
            self.tag = tag.map { (text: $0.0, colour: $0.1) }
        }
    }

    /// Called as "Why?" opens. Returns a note for the sheet when peeking had a cost, nil when it was free.
    /// - Recall: the answer is given away, so this run isn't clean (and the move counts as missed).
    /// - A due move you haven't answered yet: counts as a miss, so it comes back sooner.
    /// - A known move that isn't due: not graded this time, and never demoted.
    func notePeek() -> String? {
        guard let line else { return nil }
        if pass == .recall {
            recallClean = false
            if waiting, let n = expectedNode, kind(index) == .learn, counted.insert(key(line.rep, n)).inserted {
                countTry(false)
            }
            return "Peeking means one more run from memory."
        }
        guard waiting, let n = expectedNode, misses == 0 else { return nil }
        let k = kind(index)
        let gradeKey = key(line.rep, n)
        guard k == .graded || k == .known, !graded.contains(gradeKey) else { return nil }
        graded.insert(gradeKey)
        misses = 1
        board.tints = [n.from: .hint]
        guard k == .graded || progress.isDue(line.rep, n) else { return nil }
        progress.answer(line.rep, n, firstTryRight: false)
        countTry(false)
        slipped = true
        return "Peeking counts as a miss, so this move comes back sooner."
    }

    func coverageAfter(_ rep: Repertoire) -> Double { progress.coverage(rep) }
}
