import Foundation
import SwiftUI

/// A position to solve: one of your slips, or a chance from your games.
struct Puzzle: Identifiable, Hashable {
    enum Kind: String { case fix, punish, findAgain, theirs }
    let id: String
    let gameID: String
    let fen: String
    let best: String
    let bestLine: [String]
    let played: String          // what was played in the game ("" for challenges)
    let cls: MoveClass
    let ply: Int
    let opponent: String
    let date: Date
    let phase: Phase
    var kind: Kind = .fix
    var theme: Eval.Theme? = nil
    var prompt: String = ""
    /// A missed position brought back later in the same run: the original's id, for progress.
    var retryOf: String? = nil
    var progressID: String { retryOf ?? id }

    /// The same position again, a few positions later.
    func again(_ n: Int) -> Puzzle {
        Puzzle(id: progressID + "~\(n)", gameID: gameID, fen: fen, best: best, bestLine: bestLine, played: played, cls: cls,
               ply: ply, opponent: opponent, date: date, phase: phase, kind: kind, theme: theme, prompt: prompt, retryOf: progressID)
    }
}

enum Phase: String, CaseIterable, Codable {
    case opening = "Opening", middlegame = "Middlegame", endgame = "Endgame"
    static func of(fen: String, ply: Int) -> Phase {
        if ply < 20 { return .opening }
        var pieces = 0
        for ch in fen.split(separator: " ").first ?? "" {
            switch ch.lowercased() { case "q": pieces += 9; case "r": pieces += 5; case "b", "n": pieces += 3; default: break }
        }
        return pieces <= 26 ? .endgame : .middlegame
    }
}

/// Every game's positions, worked out once per game id (a game's moves never change).
/// Thread-safe, so the background insight builders can use it too.
final class FenCache: @unchecked Sendable {
    static let shared = FenCache()
    private let lock = NSLock()
    private var map: [String: [String]] = [:]

    func fens(_ g: GameRecord) -> [String] {
        lock.lock()
        let hit = map[g.id]
        lock.unlock()
        if let hit { return hit }
        let fresh = g.fens
        lock.lock()
        map[g.id] = fresh
        lock.unlock()
        return fresh
    }
}

@MainActor
final class GameStore: ObservableObject {
    /// Games inside the history window. Everything in the app reads these.
    @Published private(set) var games: [GameRecord] = []
    @Published private(set) var stats: ChessCom.Stats?
    /// Your chess.com picture, kept on disk so it shows offline.
    /// The name on your chess.com profile, when you've set one.
    @Published private(set) var profileName: String? = UserDefaults.standard.string(forKey: "bc.profileName")
    @Published private(set) var avatar: UIImage? = UIImage(contentsOfFile: Disk.folder.appendingPathComponent("avatar.img").path)
    @Published var status: String? = nil
    @Published private(set) var importing = false
    @Published private(set) var reviewingID: String? = nil
    @Published private(set) var reviewProgress: Double = 0
    @Published var lastError: String? = nil
    /// When the last sync finished, so coming back to the app syncs again without hammering chess.com.
    private(set) var lastSync: Date?
    @Published private var reviewQueue: [String] = []
    /// Bumped whenever reviews change, so derived data can be cached.
    @Published private(set) var revision = 0

    private var all: [GameRecord] = []
    private var reviewTask: Task<Void, Never>?
    var windowMonths = 3 { didSet { if windowMonths != oldValue { applyWindow() } } }
    /// Set by the app: the repertoires and opening book used for "book" moves and prep matching.
    var reps: [Repertoire] = [] { didSet { catchUpPrep() } }
    var book: OpeningBook?
    /// Set by the app: called once per game when its review shows you left your prep (your repertoire move, to drill).
    var onLeftPrep: ((Repertoire, RepNode) -> Void)?
    private var prepHandled = Set(UserDefaults.standard.stringArray(forKey: "bc.prepHandled") ?? [])
    private var catchingUp = false

    /// FEN before each ply plus the final one, cached per game.
    func fens(_ g: GameRecord) -> [String] { FenCache.shared.fens(g) }

    init() {
        stats = Disk.load(ChessCom.Stats.self, "stats.json")
        // Hundreds of reviewed games take a moment to decode: do it off the main thread.
        Task {
            let loaded = await Task.detached(priority: .userInitiated) { Disk.load([GameRecord].self, "games.json") ?? [] }.value
            if self.all.isEmpty { self.all = loaded } else {
                let known = Set(self.all.map(\.id))
                self.all += loaded.filter { !known.contains($0.id) }
            }
            self.loadedFromDisk = true
            self.applyWindow()
            self.catchUpPrep()
        }
    }

    /// Nothing saves or syncs until the games on disk are in memory, so a save can never drop reviews.
    private var loadedFromDisk = false
    private func waitForDisk() async {
        while !loadedFromDisk { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    /// Encoding happens off the main thread; saves are coalesced.
    private var saveTask: Task<Void, Never>?
    private func save() {
        guard loadedFromDisk else { return }
        saveTask?.cancel()
        let snapshot = all
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            Disk.save(snapshot, "games.json")
        }
    }

    private func applyWindow() {
        if windowMonths <= 0 {
            games = all
        } else {
            let cutoff = Date().addingTimeInterval(-Double(windowMonths) * 30.44 * 86_400)
            games = all.filter { $0.endTime >= cutoff }
        }
        revision += 1
    }

    var reviewed: [GameRecord] { games.filter { $0.review?.version == GameReview.currentVersion } }
    var unreviewed: [GameRecord] { games.filter { $0.review?.version != GameReview.currentVersion } }
    func game(_ id: String) -> GameRecord? { all.first { $0.id == id } }

    // MARK: Import

    /// Your Lichess username, set by the app; synced alongside chess.com.
    var lichessUser = ""

    func sync(user: String, months: Int, autoReview: Bool) async {
        let name = user.trimmingCharacters(in: .whitespaces)
        let li = lichessUser.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty || !li.isEmpty, !importing else { return }
        // Store screenshots: launched with -noSync, show the games already on the device and fetch nothing.
        if ProcessInfo.processInfo.arguments.contains("-noSync") { return }
        importing = true
        await waitForDisk()
        lastError = nil
        defer { importing = false; status = nil }
        do {
            var fresh: [GameRecord] = []
            let known = Set(all.map(\.id))
            if !name.isEmpty {
                status = "Checking \(name)…"
                if let s = try? await ChessCom.stats(name) { stats = s; Disk.save(s, "stats.json") }
                await refreshAvatar(name)
                fresh += try await ChessCom.games(name, months: months, known: known) { [weak self] msg in self?.status = msg }
            }
            if !li.isEmpty {
                status = "Fetching Lichess games…"
                let newest = all.filter { $0.id.hasPrefix("li-") }.map(\.endTime).max()
                let since = newest ?? (months <= 0 ? .distantPast : Calendar.current.date(byAdding: .month, value: -months, to: Date())!)
                fresh += try await Lichess.games(li, since: since, known: known)
            }
            all = (fresh + all).sorted { $0.endTime > $1.endTime }
            save()
            applyWindow()
            if autoReview { enqueueReviews(unreviewed.prefix(40).map(\.id)) }
            lastSync = Date()
        } catch is CancellationError {
            // Left the screen or the app mid-sync: not an error, the next sync picks up from here.
        } catch let e as URLError where e.code == .cancelled {
        } catch let e as ChessCom.Failure {
            lastError = e.errorDescription
        } catch {
            lastError = "Couldn't reach chess.com. Pull down to try again."
        }
    }

    /// Fetches the profile picture at most once a day.
    private func refreshAvatar(_ name: String) async {
        let key = "bc.avatarFetched." + name.lowercased()
        if avatar != nil, let last = UserDefaults.standard.object(forKey: key) as? Date, Date().timeIntervalSince(last) < 86_400 { return }
        guard let p = try? await ChessCom.profile(name) else { return }
        UserDefaults.standard.set(Date(), forKey: key)
        profileName = p.name.flatMap { $0.isEmpty ? nil : $0 }
        UserDefaults.standard.set(profileName, forKey: "bc.profileName")
        let file = Disk.folder.appendingPathComponent("avatar.img")
        guard let s = p.avatar, let url = URL(string: s),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let img = UIImage(data: data) else {
            try? FileManager.default.removeItem(at: file)
            avatar = nil
            return
        }
        try? data.write(to: file, options: .atomic)
        avatar = img
    }

    func removeAll() {
        all = []
        avatar = nil
        try? FileManager.default.removeItem(at: Disk.folder.appendingPathComponent("avatar.img"))
        for k in UserDefaults.standard.dictionaryRepresentation().keys where k.hasPrefix("archivesDone.") {
            UserDefaults.standard.removeObject(forKey: k)
        }
        stats = nil
        save()
        applyWindow()
    }

    // MARK: Review

    func enqueueReviews(_ ids: [String]) {
        for id in ids where !reviewQueue.contains(id) && game(id)?.review?.version != GameReview.currentVersion {
            reviewQueue.append(id)
        }
        startReviewing()
    }

    /// Put a game at the front of the queue (you opened it).
    func reviewNow(_ id: String) {
        guard game(id)?.review?.version != GameReview.currentVersion else { return }
        reviewQueue.removeAll { $0 == id }
        reviewQueue.insert(id, at: 0)
        startReviewing()
    }

    var pendingReviews: Int { reviewQueue.count + (reviewingID == nil ? 0 : 1) }
    func cancelReviews() { reviewQueue.removeAll() }

    private func startReviewing() {
        guard reviewTask == nil else { return }
        reviewTask = Task { [weak self] in
            while let self, !self.reviewQueue.isEmpty {
                let id = self.reviewQueue.removeFirst()
                guard let game = self.game(id), game.review?.version != GameReview.currentVersion else { continue }
                self.reviewingID = id
                self.reviewProgress = 0
                let bookFlags = self.bookFlags(game)
                let review = await GameReviewer.review(game, book: bookFlags) { p in self.reviewProgress = p }
                if let i = self.all.firstIndex(where: { $0.id == id }) {
                    self.all[i].review = review
                    self.save()
                }
                if let i = self.games.firstIndex(where: { $0.id == id }) { self.games[i].review = review }
                self.reviewingID = nil
                self.revision += 1
                self.feedPrep(game)
            }
            self?.reviewTask = nil
        }
    }

    /// Where you left your prep becomes a due move in opening training. Once per game, ever.
    private func feedPrep(_ g: GameRecord) {
        guard !reps.isEmpty, !prepHandled.contains(g.id) else { return }
        prepHandled.insert(g.id)
        UserDefaults.standard.set(Array(prepHandled), forKey: "bc.prepHandled")
        if let m = g.prep(in: reps), m.leftByYou, let expected = m.expected {
            onLeftPrep?(m.repertoire, expected)
        }
    }

    /// Games reviewed before this existed: worked out once, off the main thread.
    private func catchUpPrep() {
        guard loadedFromDisk, !reps.isEmpty, !catchingUp else { return }
        let todo = all.filter { $0.review?.version == GameReview.currentVersion && !prepHandled.contains($0.id) }
        guard !todo.isEmpty else { return }
        catchingUp = true
        let reps = self.reps
        Task {
            let found: [(rep: String, node: String)] = await Task.detached(priority: .utility) {
                todo.compactMap { g in
                    guard let m = g.prep(in: reps), m.leftByYou, let e = m.expected else { return nil }
                    return (m.repertoire.id, e.id)
                }
            }.value
            for g in todo { self.prepHandled.insert(g.id) }
            UserDefaults.standard.set(Array(self.prepHandled), forKey: "bc.prepHandled")
            for f in found {
                if let rep = self.reps.first(where: { $0.id == f.rep }), let node = rep.node(f.node) { self.onLeftPrep?(rep, node) }
            }
            self.catchingUp = false
        }
    }

    /// Which plies are "book": in your repertoire, or a move club players commonly make there.
    private func bookFlags(_ g: GameRecord) -> [Bool] {
        let fens = self.fens(g)
        var out: [Bool] = []
        var stillBook = true
        for (i, u) in g.ucis.enumerated() {
            guard stillBook, i < fens.count - 1, i < 24 else { out.append(false); continue }
            var isBook = reps.contains { $0.node(fen: fens[i + 1]) != nil }
            if !isBook, let e = book?.entry(fens[i]), let m = e.moves.first(where: { $0.uci == u }) {
                isBook = e.share(m) >= 0.03 && m.games >= 40
            }
            if !isBook { stillBook = false }
            out.append(isBook)
        }
        return out
    }

    // MARK: Simple stats

    func count(_ cls: MoveClass, in list: [GameRecord]? = nil) -> Int {
        (list ?? reviewed).reduce(0) { $0 + $1.count(cls) }
    }

    func accuracyTrend() -> [(Date, Double)] {
        reviewed.compactMap { g in g.userAccuracy.map { (g.endTime, $0) } }.sorted { $0.0 < $1.0 }
    }

    func ratingHistory(_ timeClass: String) -> [(Date, Int)] {
        games.filter { $0.timeClass == timeClass }.map { ($0.endTime, $0.userRating) }.sorted { $0.0 < $1.0 }
    }

    struct OpeningStat: Identifiable {
        let name: String
        let color: PieceColor
        var games = 0, wins = 0, draws = 0
        var id: String { name + color.rawValue }
        var winRate: Double { Double(wins) / Double(max(1, games)) }
        var drawRate: Double { Double(draws) / Double(max(1, games)) }
    }

    func openingStats() -> [OpeningStat] { Self.openingStats(of: games) }

    nonisolated static func openingStats(of games: [GameRecord]) -> [OpeningStat] {
        var dict: [String: OpeningStat] = [:]
        for g in games {
            let k = g.family + g.userColor.rawValue
            var s = dict[k] ?? OpeningStat(name: g.family, color: g.userColor)
            s.games += 1
            if g.result == .win { s.wins += 1 }
            if g.result == .draw { s.draws += 1 }
            dict[k] = s
        }
        return dict.values.sorted { $0.games > $1.games }
    }
}

// MARK: - Reviewer

enum GameReviewer {
    /// Stockfish with two lines per position, then chess.com's rules. Runs off the main thread; the engine
    /// yields to anything you do yourself.
    nonisolated static func review(_ game: GameRecord, book: [Bool], depth: Int = 14,
                                   progress: @escaping @MainActor (Double) -> Void) async -> GameReview {
        let fens = FenCache.shared.fens(game)
        let engine = await MainActor.run { EngineService.shared }
        var lines: [[EngineLine]] = []
        for (i, fen) in fens.enumerated() {
            switch Chess.outcome(fen) {
            case .checkmate(let winner):
                lines.append([EngineLine(rank: 1, cp: nil, mate: winner == .white ? 1 : -1, depth: 0, pv: [])])
            case .draw:
                lines.append([EngineLine(rank: 1, cp: 0, mate: nil, depth: 0, pv: [])])
            default:
                var got: [EngineLine] = []
                for _ in 0..<6 {
                    got = await engine.analyse(fen: fen, depth: depth, multipv: 2, background: true)
                    if let d = got.first?.depth, d >= depth - 2 { break }
                }
                lines.append(got)
            }
            if i % 3 == 0 || i == fens.count - 1 {
                let p = Double(i + 1) / Double(fens.count)
                await MainActor.run { progress(p) }
            }
        }
        var classes: [MoveClass] = [], evals: [Double] = [], best: [String] = [], bestLines: [[String]] = []
        var themes: [Eval.Theme?] = [], squares: [String?] = []
        var accW: [Double] = [], accB: [Double] = []
        var prevLoss: Double? = nil
        for i in 0..<min(game.ucis.count, fens.count - 1) {
            let mover = game.moverAt(i)
            let ctx = Eval.Context(fenBefore: fens[i], fenAfter: fens[i + 1], mover: mover, played: game.ucis[i],
                                   best: lines[i], after: lines[i + 1].first, isBook: i < book.count && book[i],
                                   opponentLoss: prevLoss, previous: i > 0 ? game.ucis[i - 1] : nil)
            let v = Eval.classify(ctx)
            classes.append(v.cls)
            themes.append(v.theme)
            squares.append(v.square)
            let a = lines[i + 1].first
            evals.append(a.map { $0.mate != nil ? ($0.mate! > 0 ? 1500 : -1500) : ($0.cp ?? 0) } ?? 0)
            best.append(lines[i].first?.best ?? "")
            bestLines.append(Array((lines[i].first?.pv ?? []).prefix(12)))
            let acc = Eval.moveAccuracy(winBefore: v.before * 100, winAfter: v.after * 100)
            if mover == .white { accW.append(acc) } else { accB.append(acc) }
            prevLoss = v.loss
        }
        // After the last move: the final position's best line, so "show why" works for the last move too.
        if let last = lines.last?.first { bestLines.append(Array(last.pv.prefix(12))) }
        func mean(_ a: [Double]) -> Double {
            guard !a.isEmpty else { return 0 }
            // Lichess-style: average of the plain mean and the harmonic mean, so one blunder counts.
            let m = a.reduce(0, +) / Double(a.count)
            let h = Double(a.count) / a.map { 1 / max(1, $0) }.reduce(0, +)
            return (m + h) / 2
        }
        return GameReview(classes: classes, evals: evals, best: best, bestLines: bestLines,
                          accuracyWhite: mean(accW), accuracyBlack: mean(accB), depth: depth, reviewedAt: Date(),
                          themes: themes, squares: squares, version: GameReview.currentVersion)
    }
}

/// A tiny repeatable random generator, so the daily set is the same all day.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}
