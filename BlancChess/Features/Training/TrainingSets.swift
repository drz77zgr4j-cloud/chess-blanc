import SwiftUI

/// Everything derived from your reviewed games, as plain values.
struct TrainingSnapshot {
    var weaknesses: [Weakness] = []
    var slips: [Puzzle] = []                    // newest first
    var chances: [Puzzle] = []                  // newest first
    var phases: [(Phase, Double)] = []
    var openings: [GameStore.OpeningStat] = []  // most played first
    /// Where an opening's games sit in your repertoire: the last repertoire position they reached.
    var openingNodes: [String: OpeningSpot] = [:]

    struct OpeningSpot { let rep: String; let node: String }

    /// The heavy part. A pure function of its inputs, so it runs off the main thread.
    static func build(reviewed: [GameRecord], games: [GameRecord], reps: [Repertoire]) -> TrainingSnapshot {
        var s = TrainingSnapshot()
        s.weaknesses = Insights.weaknesses(games: reviewed, reps: reps)
        s.slips = Insights.mistakes(games: reviewed).sorted { $0.date > $1.date }
        s.chances = Insights.challenges(games: reviewed).sorted { $0.date > $1.date }
        s.phases = Insights.phaseRates(games: reviewed)
        s.openings = GameStore.openingStats(of: games)
        for stat in s.openings.prefix(6) {
            let sample = games.filter { $0.family == stat.name && $0.userColor == stat.color }
                .sorted { $0.endTime > $1.endTime }.prefix(3)
            let preps = sample.compactMap { $0.prep(in: reps) }
            if let m = preps.first(where: { $0.lastNode.map { !$0.isRoot } ?? false }), let n = m.lastNode {
                s.openingNodes[stat.id] = OpeningSpot(rep: m.repertoire.id, node: n.id)
            }
        }
        return s
    }
}

/// Heavy derived data from your reviewed games, worked out once per `GameStore.revision`, off the main thread.
/// Today, Insights, Weakness and the puzzle runs all read from here, so nothing is computed twice.
@MainActor
final class TrainingCache {
    static let shared = TrainingCache()

    private struct Key: Equatable { let revision: Int; let reps: Int }

    /// The newest finished snapshot.
    private(set) var latest: TrainingSnapshot?
    private var latestKey: Key?
    private var building: (key: Key, task: Task<TrainingSnapshot, Never>)?

    /// The snapshot for the store as it is now. Only reading the store happens on the main actor:
    /// the games are copied first, and the work runs detached.
    func snapshot(_ store: GameStore, _ reps: [Repertoire]) async -> TrainingSnapshot {
        let key = Key(revision: store.revision, reps: reps.count)
        if let latest, latestKey == key { return latest }
        if let b = building, b.key == key { return await b.task.value }
        let reviewed = store.reviewed
        let games = store.games
        let task = Task.detached(priority: .userInitiated) {
            TrainingSnapshot.build(reviewed: reviewed, games: games, reps: reps)
        }
        building = (key, task)
        let s = await task.value
        if building?.key == key {
            building = nil
            latest = s
            latestKey = key
        }
        return s
    }

    // MARK: Sets

    /// The positions a run covers.
    func puzzles(for source: PuzzleSet.Source, _ store: GameStore, _ reps: [Repertoire], _ progress: ProgressStore) async -> [Puzzle] {
        let s = await snapshot(store, reps)
        switch source {
        case .daily:
            return DailySet.puzzles(s, progress)
        case .mistakes(let filter):
            guard let f = filter else { return s.slips }
            return s.slips.filter { $0.phase.rawValue == f || $0.cls.rawValue == f }
        case .weakness(let kind):
            return s.weaknesses.first { $0.kind.rawValue == kind }?.examples ?? []
        case .game(let id):
            return s.slips.filter { $0.gameID == id }.sorted { $0.ply < $1.ply }
        }
    }
}

/// Today's positions: up to six, your slips plus chances from your games. Picked once a day, the first time
/// there is anything to pick, and kept all day: new reviews never top it up, so "All done" stays done.
@MainActor
enum DailySet {
    static let size = 6

    private static var key: String { "bc.daily." + ProgressStore.today }
    private static var triedKey: String { "bc.dailyTried." + ProgressStore.today }

    private static var seed: UInt64 {
        UInt64(ProgressStore.today.replacingOccurrences(of: "-", with: "")) ?? 1
    }

    static func puzzles(_ s: TrainingSnapshot, _ progress: ProgressStore) -> [Puzzle] {
        var byID: [String: Puzzle] = [:]
        for p in s.slips + s.chances { byID[p.id] = p }
        if let ids = UserDefaults.standard.stringArray(forKey: key) {
            return ids.compactMap { byID[$0] }
        }
        // First time today: four slips and two chances from what isn't fixed yet, deterministic for the day.
        var rng = SeededRandom(seed: seed)
        let openSlips = s.slips.filter { progress.puzzleState($0.id) != true }
            .sorted { $0.id < $1.id }.shuffled(using: &rng)
        let openChances = s.chances.filter { progress.puzzleState($0.id) != true }
            .sorted { $0.id < $1.id }.shuffled(using: &rng)
        let chanceTarget = min(openChances.count, 2)
        var pick = Array(openSlips.prefix(size - chanceTarget))
        pick += openChances.prefix(size - pick.count)
        guard !pick.isEmpty else { return [] }   // nothing to pick yet: try again once reviews land
        var ids = pick.map(\.id)
        var mix = SeededRandom(seed: seed &+ 7)
        ids.shuffle(using: &mix)
        UserDefaults.standard.set(ids, forKey: key)
        return ids.compactMap { byID[$0] }
    }

    /// Positions from today's set you've already had a go at.
    static var triedToday: Set<String> { Set(UserDefaults.standard.stringArray(forKey: triedKey) ?? []) }

    static func markTried(_ id: String) {
        var s = triedToday
        guard !s.contains(id) else { return }
        s.insert(id)
        UserDefaults.standard.set(Array(s), forKey: triedKey)
    }
}

// MARK: - Bits shared by the training screens

extension Puzzle {
    var playedPly: Ply? { played.isEmpty ? nil : Chess.play(played, on: fen) }
    var bestPly: Ply? { Chess.play(best, on: fen) }
    var playedMove: MovePair? { played.count >= 4 ? MovePair(from: String(played.prefix(2)), to: String(played.dropFirst(2).prefix(2))) : nil }
    var bestMove: MovePair? { best.count >= 4 ? MovePair(from: String(best.prefix(2)), to: String(best.dropFirst(2).prefix(2))) : nil }
    var isChallenge: Bool { kind != .fix }
    /// Whose move it is (the board is shown from this side).
    var side: PieceColor { Chess.sideToMove(fen) }

    /// "15…Ra3".
    var playedText: String { playedPly.map { Chess.numbered($0.san, fenBefore: fen) } ?? "?" }

    /// One line for list rows.
    var listTitle: String {
        switch kind {
        case .fix: cls == .book ? "You left your prep: \(playedText)" : "You played \(playedText)"
        case .punish: "Punish their mistake"
        case .findAgain: "Find your \(cls.title.lowercased()) move"
        case .theirs: "Find their \(cls.title.lowercased()) move"
        }
    }
}

/// Fixed, missed, or not tried yet.
enum PuzzleStatus {
    case fixed, missed, new
    init(_ state: Bool?) { self = state == true ? .fixed : state == false ? .missed : .new }
    var label: String { switch self { case .fixed: "Fixed"; case .missed: "Missed"; case .new: "New" } }
    var colour: Color { switch self { case .fixed: BC.mint; case .missed: BC.coral; case .new: BC.mute } }
}

/// A list thumbnail: the position with the move that was played drawn as a red arrow.
struct SlipBoard: View {
    let fen: String
    var size: CGFloat = 64
    var flipped = false
    var move: MovePair? = nil
    var colour: Color = BC.coral
    var radius: CGFloat = 9

    var body: some View {
        MiniBoard(fen: fen, size: size, flipped: flipped, highlight: [], radius: radius)
            .overlay {
                if let move {
                    Canvas { ctx, _ in
                        let q = size / 8
                        func centre(_ sq: String) -> CGPoint {
                            let f = CGFloat(Int(sq.unicodeScalars.first!.value) - 97)
                            let r = CGFloat(Int(String(sq.last!)) ?? 1)
                            let col = flipped ? 7 - f : f
                            let row = flipped ? r - 1 : 8 - r
                            return CGPoint(x: (col + 0.5) * q, y: (row + 0.5) * q)
                        }
                        let p2 = centre(move.to), c1 = centre(move.from)
                        let p1 = CGPoint(x: c1.x + (p2.x - c1.x) * 0.08, y: c1.y + (p2.y - c1.y) * 0.08)
                        let dx = p2.x - p1.x, dy = p2.y - p1.y
                        let len = max(1, sqrt(dx * dx + dy * dy))
                        let ux = dx / len, uy = dy / len, nx = -uy, ny = ux
                        let head = q * 0.62, w = q * 0.17, hw = q * 0.42
                        let base = CGPoint(x: p2.x - ux * head, y: p2.y - uy * head)
                        var path = Path()
                        path.move(to: CGPoint(x: p1.x + nx * w, y: p1.y + ny * w))
                        path.addLine(to: CGPoint(x: base.x + nx * w, y: base.y + ny * w))
                        path.addLine(to: CGPoint(x: base.x + nx * hw, y: base.y + ny * hw))
                        path.addLine(to: p2)
                        path.addLine(to: CGPoint(x: base.x - nx * hw, y: base.y - ny * hw))
                        path.addLine(to: CGPoint(x: base.x - nx * w, y: base.y - ny * w))
                        path.addLine(to: CGPoint(x: p1.x - nx * w, y: p1.y - ny * w))
                        path.closeSubpath()
                        ctx.fill(path, with: .color(colour.opacity(0.92)))
                    }
                    .frame(width: size, height: size)
                    .allowsHitTesting(false)
                }
            }
    }
}

/// Hands a start to a puzzle run opened by route (routes only carry the set): a given position,
/// or straight into solving from the first one that isn't fixed.
@MainActor
enum PuzzleLaunch {
    enum Start: Equatable { case at(String), first }
    private static var pending: (PuzzleSet, Start)?
    static func start(_ set: PuzzleSet, at id: String) { pending = (set, .at(id)) }
    /// Skip the list and go straight to solving.
    static func startSolving(_ set: PuzzleSet) { pending = (set, .first) }
    static func take(for set: PuzzleSet) -> Start? {
        guard let p = pending, p.0 == set else { return nil }
        pending = nil
        return p.1
    }
}

/// "Good evening" and friends.
enum DayText {
    static var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 5 ? "Good evening" : h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
    }

    /// "at 18:40", "tomorrow at 09:10", "on Fri 21 Nov".
    static func when(_ d: Date) -> String {
        let cal = Calendar.current
        let time = d.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(d) { return "at \(time)" }
        if cal.isDateInTomorrow(d) { return "tomorrow at \(time)" }
        return "on " + d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}
