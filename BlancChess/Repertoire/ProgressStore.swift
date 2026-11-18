import Foundation
import SwiftUI

/// Saves Codable values as JSON in Application Support.
enum Disk {
    static var folder: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BlancChess", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, _ name: String) {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        guard let data = try? e.encode(value) else { return }
        try? data.write(to: folder.appendingPathComponent(name), options: .atomic)
    }
}

// MARK: - Settings

struct AppSettings: Codable, Equatable {
    var sound = true
    var haptics = true
    var coordinates = true
    var moveArrows = true
    var engineDepth = 18
    var engineLines = 3
    var newMovesPerDay = 8
    var chessComUser = ""
    var historyMonths = 3          // 0 = all time
    var autoReview = true
    var botElo = 1000
    var name = ""                  // what Today calls you
    var blunderGuard = true        // warn before a move that hangs a piece, in bot games
    var boardTheme = "wood"
    var pieceSet = "classic"
    var lichessUser = ""
    /// A chess.com or Lichess account is linked.
    var linked: Bool { !chessComUser.isEmpty || !lichessUser.isEmpty }

    init() {}

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let b = AppSettings()
        sound = try c.decodeIfPresent(Bool.self, forKey: .sound) ?? b.sound
        haptics = try c.decodeIfPresent(Bool.self, forKey: .haptics) ?? b.haptics
        coordinates = try c.decodeIfPresent(Bool.self, forKey: .coordinates) ?? b.coordinates
        moveArrows = try c.decodeIfPresent(Bool.self, forKey: .moveArrows) ?? b.moveArrows
        engineDepth = try c.decodeIfPresent(Int.self, forKey: .engineDepth) ?? b.engineDepth
        engineLines = try c.decodeIfPresent(Int.self, forKey: .engineLines) ?? b.engineLines
        newMovesPerDay = try c.decodeIfPresent(Int.self, forKey: .newMovesPerDay) ?? b.newMovesPerDay
        chessComUser = try c.decodeIfPresent(String.self, forKey: .chessComUser) ?? b.chessComUser
        historyMonths = try c.decodeIfPresent(Int.self, forKey: .historyMonths) ?? b.historyMonths
        autoReview = try c.decodeIfPresent(Bool.self, forKey: .autoReview) ?? b.autoReview
        botElo = try c.decodeIfPresent(Int.self, forKey: .botElo) ?? b.botElo
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? b.name
        blunderGuard = try c.decodeIfPresent(Bool.self, forKey: .blunderGuard) ?? b.blunderGuard
        boardTheme = try c.decodeIfPresent(String.self, forKey: .boardTheme) ?? b.boardTheme
        pieceSet = try c.decodeIfPresent(String.self, forKey: .pieceSet) ?? b.pieceSet
        lichessUser = try c.decodeIfPresent(String.self, forKey: .lichessUser) ?? b.lichessUser
    }

    static let historyOptions: [(Int, String)] = [(1, "30 days"), (3, "90 days"), (6, "6 months"), (12, "1 year"), (0, "All time")]
    static func historyName(_ m: Int) -> String { historyOptions.first { $0.0 == m }?.1 ?? "\(m) months" }
}

// MARK: - Move memory (spaced repetition)

/// How well one of your repertoire moves is remembered.
struct MoveMemory: Codable {
    var level = 0                 // 0 = not learned yet; 1…7 climb the ladder
    var due: Date? = nil
    var reviews = 0
    var lapses = 0                // first tries that were wrong
    var lastSeen: Date? = nil
}

enum MemoryState: Int, Comparable {
    case new, learning, known, mastered
    static func < (a: MemoryState, b: MemoryState) -> Bool { a.rawValue < b.rawValue }
    var label: String { switch self { case .new: "New"; case .learning: "Learning"; case .known: "Known"; case .mastered: "Mastered" } }
    var colour: Color { switch self { case .new: BC.mute; case .learning: BC.blue; case .known: BC.mint; case .mastered: BC.mint } }
}

struct TrainingData: Codable {
    var moves: [String: MoveMemory] = [:]       // "<rep>|<node id>"
    var practiceDays: [String] = []
    var firstTryRight = 0
    var firstTryWrong = 0
    var puzzles: [String: Bool] = [:]           // puzzle id -> solved first try
    var endgames: [String: Int] = [:]
    var newToday: [String: Int] = [:]           // day -> new moves learned
    var priority: [String] = []                 // new moves you missed in real games: learn these first

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        moves = try c.decodeIfPresent([String: MoveMemory].self, forKey: .moves) ?? [:]
        practiceDays = try c.decodeIfPresent([String].self, forKey: .practiceDays) ?? []
        firstTryRight = try c.decodeIfPresent(Int.self, forKey: .firstTryRight) ?? 0
        firstTryWrong = try c.decodeIfPresent(Int.self, forKey: .firstTryWrong) ?? 0
        puzzles = try c.decodeIfPresent([String: Bool].self, forKey: .puzzles) ?? [:]
        endgames = try c.decodeIfPresent([String: Int].self, forKey: .endgames) ?? [:]
        priority = try c.decodeIfPresent([String].self, forKey: .priority) ?? []
        newToday = try c.decodeIfPresent([String: Int].self, forKey: .newToday) ?? [:]
    }
}

/// Learning progress and settings. One per app.
@MainActor
final class ProgressStore: ObservableObject {
    @Published private(set) var data: TrainingData { didSet { version &+= 1 } }
    /// Bumped whenever training data changes, so the counts below can be cached (Today re-renders often).
    private(set) var version = 0
    private var memoVersion = -1
    private var coverageMemo: [String: Double] = [:]
    private var countsMemo: [String: (learned: Int, total: Int, due: Int, at: Date)] = [:]
    private var planMemo: (key: String, due: Int, fresh: Int, next: Date?, at: Date)?
    @Published var settings: AppSettings {
        didSet { Disk.save(settings, "settings-v2.json"); apply() }
    }

    /// The ladder: 4 hours, then 1, 3, 7, 14, 30, 90 days.
    static let ladder: [TimeInterval] = [4 * 3600, 86_400, 3 * 86_400, 7 * 86_400, 14 * 86_400, 30 * 86_400, 90 * 86_400]

    init() {
        data = Disk.load(TrainingData.self, "training-v2.json") ?? TrainingData()
        settings = Disk.load(AppSettings.self, "settings-v2.json") ?? ProgressStore.migratedSettings()
        apply()
    }

    private static func migratedSettings() -> AppSettings {
        var s = AppSettings()
        struct Old: Decodable { var chessComUser: String?; var importMonths: Int?; var botElo: Int?; var sound: Bool?; var haptics: Bool? }
        if let o = Disk.load(Old.self, "settings.json") {
            s.chessComUser = o.chessComUser ?? ""
            s.historyMonths = o.importMonths ?? 3
            s.botElo = o.botElo ?? 1000
            s.sound = o.sound ?? true
            s.haptics = o.haptics ?? true
        }
        return s
    }

    private func apply() {
        Feel.soundOn = settings.sound
        Feel.hapticsOn = settings.haptics
        BoardTheme.current = BoardTheme.named(settings.boardTheme)
        PieceSet.current = PieceSet.named(settings.pieceSet)
    }

    private func save() { Disk.save(data, "training-v2.json") }

    private func key(_ rep: Repertoire, _ n: RepNode) -> String { rep.id + "|" + n.id }

    func memory(_ rep: Repertoire, _ n: RepNode) -> MoveMemory { data.moves[key(rep, n)] ?? MoveMemory() }

    func state(_ rep: Repertoire, _ n: RepNode) -> MemoryState {
        let m = memory(rep, n)
        switch m.level {
        case 0: return .new
        case 1...3: return .learning
        case 4...5: return .known
        default: return .mastered
        }
    }

    func isDue(_ rep: Repertoire, _ n: RepNode, now: Date = Date()) -> Bool {
        let m = memory(rep, n)
        return m.level > 0 && (m.due ?? .distantPast) <= now
    }

    /// First exposure finished (seen, played with help, then recalled cleanly once).
    func learned(_ rep: Repertoire, _ n: RepNode) {
        var m = memory(rep, n)
        guard m.level == 0 else { return }
        m.level = 1
        m.due = Date().addingTimeInterval(Self.ladder[0])
        m.lastSeen = Date()
        data.moves[key(rep, n)] = m
        data.newToday[Self.today, default: 0] += 1
        markPracticed()
        save()
    }

    /// A graded answer. Only the first try counts: right climbs one rung (if it was due), wrong drops one (never below learning).
    @discardableResult
    func answer(_ rep: Repertoire, _ n: RepNode, firstTryRight: Bool) -> MoveMemory {
        var m = memory(rep, n)
        let wasDue = m.level == 0 || (m.due ?? .distantPast) <= Date()
        if firstTryRight {
            data.firstTryRight += 1
            if m.level == 0 {
                m.level = 1
                data.newToday[Self.today, default: 0] += 1
            } else if wasDue {
                m.level = min(Self.ladder.count, m.level + 1)
            }
        } else {
            data.firstTryWrong += 1
            m.lapses += 1
            // One rung down (never below "learning"): a slip brings the move back soon without wiping progress.
            m.level = max(1, m.level - 1)
        }
        m.reviews += 1
        m.lastSeen = Date()
        if firstTryRight && !wasDue, let d = m.due {
            m.due = d   // reviewed early: keep the schedule
        } else {
            m.due = Date().addingTimeInterval(Self.ladder[max(0, m.level - 1)])
        }
        data.moves[key(rep, n)] = m
        markPracticed()
        save()
        return m
    }

    /// A move you got wrong in a real game: due now, at least "learning", and counted as a lapse.
    /// You left your repertoire here in a real game. A move you'd learned comes back now;
    /// one you hadn't learned yet jumps to the front of the new-move queue (it doesn't count as learned).
    func markDue(_ rep: Repertoire, _ n: RepNode) {
        let k = key(rep, n)
        var m = memory(rep, n)
        if m.level == 0 {
            if !data.priority.contains(k) { data.priority.append(k) }
        } else {
            m.due = Date()
            m.lapses += 1
            data.moves[k] = m
        }
        save()
    }

    /// New moves with the ones you missed in your games first, otherwise in the given order.
    func prioritised(_ rep: Repertoire, _ nodes: [RepNode]) -> [RepNode] {
        guard !data.priority.isEmpty else { return nodes }
        let p = Set(data.priority)
        return nodes.filter { p.contains(key(rep, $0)) } + nodes.filter { !p.contains(key(rep, $0)) }
    }

    // MARK: Cache

    private func memoKey(_ rep: Repertoire, _ chapter: Chapter?) -> String { rep.id + "|" + (chapter?.id ?? "") }

    private func syncMemo() {
        guard memoVersion != version else { return }
        memoVersion = version
        coverageMemo = [:]
        countsMemo = [:]
        planMemo = nil
    }

    /// Today's opening work across repertoires: due moves, new moves, and when the next one falls due.
    /// Cached on the training data (and refreshed every 30 s, since due dates pass with time).
    func planCounts(_ reps: [Repertoire]) -> (due: Int, fresh: Int, next: Date?) {
        syncMemo()
        let k = reps.map(\.id).joined(separator: ",")
        let now = Date()
        if let p = planMemo, p.key == k, now.timeIntervalSince(p.at) < 30, p.next.map({ $0 > now }) ?? true {
            return (p.due, p.fresh, p.next)
        }
        var due = 0, fresh = 0
        var next: Date?
        for rep in reps {
            for n in rep.myMoves {
                let m = memory(rep, n)
                if m.level == 0 { fresh += 1; continue }
                let d = m.due ?? .distantPast
                if d <= now { due += 1 } else if next == nil || d < next! { next = d }
            }
        }
        planMemo = (k, due, fresh, next, now)
        return (due, fresh, next)
    }

    // MARK: Queues

    func dueMoves(_ rep: Repertoire, in chapter: Chapter? = nil) -> [RepNode] {
        let now = Date()
        let pool = chapter.map { rep.myMoves(in: $0) } ?? rep.myMoves
        return pool.filter { isDue(rep, $0, now: now) }
    }

    /// Moves not learned yet, most common position first.
    func newMoves(_ rep: Repertoire, in chapter: Chapter? = nil) -> [RepNode] {
        let pool = chapter.map { rep.myMoves(in: $0) } ?? rep.myMoves
        return pool.filter { memory(rep, $0).level == 0 }
    }

    var newLearnedToday: Int { data.newToday[Self.today] ?? 0 }

    /// Days with practice, and new moves learned, between two dates (for the weekly report).
    func practisedDays(from a: Date, to b: Date) -> Int {
        data.practiceDays.compactMap { Self.dayFormat.date(from: $0) }.filter { $0 >= Calendar.current.startOfDay(for: a) && $0 < b }.count
    }
    func movesLearned(from a: Date, to b: Date) -> Int {
        data.newToday.reduce(0) { acc, kv in
            guard let d = Self.dayFormat.date(from: kv.key), d >= Calendar.current.startOfDay(for: a), d < b else { return acc }
            return acc + kv.value
        }
    }

    // MARK: Progress

    /// Share of the games you'll actually play where you'd still know your move: each move weighted by
    /// how often its position comes up. This is the number that grows every session.
    func coverage(_ rep: Repertoire, in chapter: Chapter? = nil) -> Double {
        syncMemo()
        let k = memoKey(rep, chapter)
        if let c = coverageMemo[k] { return c }
        let c = computeCoverage(rep, in: chapter)
        coverageMemo[k] = c
        return c
    }

    private func computeCoverage(_ rep: Repertoire, in chapter: Chapter?) -> Double {
        let pool = chapter.map { rep.myMoves(in: $0) } ?? rep.myMoves
        var have = 0.0, all = 0.0
        for n in pool {
            let w = max(n.reach, 0.0005)
            all += w
            have += w * strength(memory(rep, n).level)
        }
        return all == 0 ? 0 : have / all
    }

    private func strength(_ level: Int) -> Double {
        switch level { case 0: 0; case 1: 0.35; case 2: 0.55; case 3: 0.75; case 4: 0.9; default: 1 }
    }

    func counts(_ rep: Repertoire, in chapter: Chapter? = nil) -> (learned: Int, total: Int, due: Int) {
        syncMemo()
        let k = memoKey(rep, chapter)
        let now = Date()
        if let c = countsMemo[k], now.timeIntervalSince(c.at) < 30 { return (c.learned, c.total, c.due) }
        let c = computeCounts(rep, in: chapter, now: now)
        countsMemo[k] = (c.learned, c.total, c.due, now)
        return c
    }

    private func computeCounts(_ rep: Repertoire, in chapter: Chapter?, now: Date) -> (learned: Int, total: Int, due: Int) {
        let pool = chapter.map { rep.myMoves(in: $0) } ?? rep.myMoves
        var learned = 0, due = 0
        for n in pool {
            let m = memory(rep, n)
            if m.level > 0 { learned += 1 }
            if m.level > 0 && (m.due ?? .distantPast) <= now { due += 1 }
        }
        return (learned, pool.count, due)
    }

    /// Moves you most often get wrong.
    func leaks(_ rep: Repertoire, limit: Int = 5) -> [RepNode] {
        rep.myMoves.filter { memory(rep, $0).lapses > 0 }
            .sorted { memory(rep, $0).lapses > memory(rep, $1).lapses }
            .prefix(limit).map { $0 }
    }

    var firstTryAccuracy: Double? {
        let t = data.firstTryRight + data.firstTryWrong
        return t == 0 ? nil : Double(data.firstTryRight) / Double(t)
    }

    // MARK: Streak

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    static var today: String { dayFormat.string(from: Date()) }

    func markPracticed() {
        if !data.practiceDays.contains(Self.today) { data.practiceDays.append(Self.today) }
    }

    var practisedToday: Bool { data.practiceDays.contains(Self.today) }

    var streak: Int {
        let days = Set(data.practiceDays)
        var count = 0
        var day = Date()
        if !days.contains(Self.dayFormat.string(from: day)) { day = Calendar.current.date(byAdding: .day, value: -1, to: day)! }
        while days.contains(Self.dayFormat.string(from: day)) {
            count += 1
            day = Calendar.current.date(byAdding: .day, value: -1, to: day)!
        }
        return count
    }

    var bestStreak: Int {
        let sorted = data.practiceDays.compactMap { Self.dayFormat.date(from: $0) }.sorted()
        var best = 0, run = 0
        var prev: Date?
        for d in sorted {
            if let p = prev, Calendar.current.dateComponents([.day], from: p, to: d).day == 1 { run += 1 } else { run = 1 }
            best = max(best, run)
            prev = d
        }
        return best
    }

    // MARK: Puzzles and endgames

    func puzzleState(_ id: String) -> Bool? { data.puzzles[id] }

    func recordPuzzle(_ id: String, solved: Bool) {
        // Once solved cleanly it stays solved unless missed again.
        data.puzzles[id] = solved
        markPracticed()
        save()
    }

    func markEndgame(_ id: String) {
        data.endgames[id, default: 0] += 1
        markPracticed()
        save()
    }

    func resetTraining() {
        data = TrainingData()
        save()
    }
}
