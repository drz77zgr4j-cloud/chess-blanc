import SwiftUI
import ChessKit

/// Everything the Board tab knows: the moves, the engine, the judge and the bot.
/// One board, two modes. All engine work runs in one cancellable task, so a new move never waits on an old search.
@MainActor
final class BoardModel: ObservableObject {
    /// The Board tab keeps its board when you switch tabs.
    static let tabRoot = BoardModel(start: nil)

    enum Mode: Equatable { case analyse, bot }
    enum EngineMode: String { case lines, judge, off }
    enum SideChoice: String, CaseIterable, Hashable { case white, black, random }

    /// A move that has been marked.
    struct Judged: Equatable {
        let ply: Ply
        let fenBefore: String
        let mover: PieceColor
        let cls: MoveClass
        let headline: String
        let detail: String
        let best: String?
        let bestSAN: String?
        let pv: [String]
        /// Stockfish's line after the move was played.
        var reply: [String] = []
        let before: Double
        let after: Double
        var loss: Double { max(0, before - after) }
        var wasBest: Bool { best == nil || best == ply.uci || cls == .forced }
        /// The line that shows why the move works: the move itself, then how play goes on.
        var whyLine: [String] {
            if pv.first == ply.uci { return pv }
            return [ply.uci] + reply
        }
        /// A brilliant move gets "Show why".
        var hasWhy: Bool { cls == .brilliant && whyLine.count > 1 }
        var accuracy: Double { Eval.moveAccuracy(winBefore: before * 100, winAfter: after * 100) }
    }

    /// Stockfish's choice, shown after "Best move" in Analyse.
    struct BestHint: Equatable {
        let fen: String
        let pv: [String]
        let san: String
    }

    struct BotGame: Equatable {
        var side: PieceColor
        var choice: SideChoice
        var elo: Int
        var startIndex: Int
        /// Opens with the moves your chess.com opponents actually play against you.
        var opponents = false
    }

    /// Your opponents' moves in the opening, by position: what the bot plays when `opponents` is on.
    var opponentBook: OpponentBook?

    struct GameResult: Equatable {
        enum Kind { case win, loss, draw }
        let kind: Kind
        let reason: String
        let accuracy: Double?
        let counts: [MoveClass: Int]
        let moves: Int
    }

    /// One engine line ready to show.
    struct ShownLine: Identifiable, Equatable {
        let id: Int
        let eval: String
        let text: String
        let pv: [String]
    }

    let board = BoardState()
    let preview = BoardState()
    let player = LinePlayer()
    let owner = "board-" + UUID().uuidString
    let start: BoardStart?

    @Published private(set) var root: String
    @Published private(set) var plies: [Ply] = []
    @Published private(set) var index = 0
    @Published private(set) var mode: Mode = .analyse
    @Published private(set) var engineMode: EngineMode
    @Published private(set) var lines: [ShownLine] = []
    @Published private(set) var depth: Int?
    @Published private(set) var bar: (cp: Double?, mate: Int?) = (0, nil)
    @Published private(set) var judged: [Int: Judged] = [:]
    @Published private(set) var checking: Int?
    @Published private(set) var hint: BestHint?
    @Published private(set) var retrying: Judged?
    @Published private(set) var playingLine = false
    @Published private(set) var lineShown = false
    @Published private(set) var game: BotGame?
    @Published private(set) var botThinking = false
    @Published private(set) var result: GameResult?
    @Published private(set) var showingBest: Judged?
    /// The line on the preview board is the "why" of a good move, not a better one.
    @Published private(set) var showingWhy = false
    /// The bot's search came back empty twice: it waits for Retry instead of freezing.
    @Published private(set) var botStuck = false
    /// Bumped when a bot game ends, so the screen can show the result.
    @Published private(set) var gameOverCount = 0

    private(set) var settings = AppSettings()
    private var book: OpeningBook?
    private var reps: [Repertoire] = []
    private var cache: [String: [EngineLine]] = [:]
    private var names: [String: String] = [:]
    private var work: Task<Void, Never>?
    private var lineTask: Task<Void, Never>?
    private var active = false

    init(start: BoardStart?) {
        self.start = start
        let s = start ?? BoardStart()
        root = s.fen
        engineMode = EngineMode(rawValue: UserDefaults.standard.string(forKey: "board.engineMode") ?? "") ?? .lines
        plies = Chess.replay(s.history, from: s.fen)
        index = plies.count
        board.bothSides = true
        board.flipped = s.flipped
        board.onMove = { [weak self] from, to, promo in self?.userMove(from: from, to: to, promo: promo) }
        showPosition(animated: false)
    }

    // MARK: - Reading

    var fen: String { fen(at: index) }
    func fen(at i: Int) -> String { i <= 0 ? root : plies[min(i, plies.count) - 1].fenAfter }
    var sideToMove: PieceColor { Chess.sideToMove(fen) }

    var outcomeText: String? {
        switch Chess.outcome(fen) {
        case .checkmate(let w): "Checkmate · \(w.name) wins"
        case .draw(let r): "Draw · \(Self.drawReason(r))"
        default: nil
        }
    }

    /// The most specific opening name on the way to the current position.
    var openingName: String? {
        guard let book else { return nil }
        var i = index
        while i >= 0 {
            let key = Repertoire.key(fen(at: i))
            if let n = names[key] { return n.isEmpty ? nil : n }
            if let n = book.name(fen(at: i)) { names[key] = n; return n }
            i -= 1
        }
        return nil
    }

    /// The verdict to show for the current move in Analyse.
    var currentJudged: Judged? { judged[index] }

    /// Your latest marked move in the bot game.
    var lastBotVerdict: (index: Int, judged: Judged)? {
        guard let g = game else { return nil }
        let key = judged.keys.filter { $0 > g.startIndex && $0 <= plies.count && judged[$0]?.mover == g.side }.max()
        return key.flatMap { k in judged[k].map { (k, $0) } }
    }

    var canTakeBack: Bool {
        guard let g = game, result == nil else { return false }
        return (g.startIndex..<plies.count).contains { Chess.sideToMove(fen(at: $0)) == g.side }
    }

    /// The repertoire move in this position, if one of your repertoires has it.
    func repertoireMove(at fen: String) -> String? {
        guard let rep = reps.first(where: { $0.color == Chess.sideToMove(fen) }), let n = rep.node(fen: fen),
              let mine = rep.myMove(after: n) else { return nil }
        return Chess.play(mine.uci, on: fen)?.uci ?? mine.uci
    }

    var bookEntry: OpeningBook.Entry? { book?.entry(fen) }
    var hasBook: Bool { book != nil }

    // MARK: - Setup

    func configure(settings: AppSettings, book: OpeningBook?, reps: [Repertoire]) {
        let linesChanged = settings.engineLines != self.settings.engineLines || settings.engineDepth != self.settings.engineDepth
        let arrowsChanged = settings.moveArrows != self.settings.moveArrows
        self.settings = settings
        self.book = book
        self.reps = reps
        board.showCoordinates = settings.coordinates
        preview.showCoordinates = settings.coordinates
        if active, linesChanged || arrowsChanged { refresh() }
    }

    func resume() {
        active = true
        showPosition(animated: false)
        refresh()
    }

    func pause() {
        active = false
        work?.cancel()
        lineTask?.cancel()
        playingLine = false
        checking = nil
        stopEngine()
    }

    private func stopEngine() {
        let o = owner
        Task { await EngineService.shared.stop(owner: o) }
    }

    // MARK: - Moving

    /// A move the blunder guard stopped: what it would hang, waiting for "Play it anyway" or another move.
    struct GuardWarning { let ply: Ply; let before: String; let text: String; let square: String }
    @Published private(set) var guardWarning: GuardWarning?

    private func userMove(from: String, to: String, promo: Piece.Kind?) {
        let before = fen
        guard let p = Chess.move(from: from, to: to, promotion: promo, on: before) else { return }
        switch mode {
        case .bot:
            guard let g = game, result == nil, showingBest == nil, Chess.sideToMove(before) == g.side, !botThinking else { return }
            if guardWarning != nil { clearGuard() }
            if settings.blunderGuard, let w = BlunderGuard.warning(before: before, ply: p) {
                guardWarning = GuardWarning(ply: p, before: before, text: w.text, square: w.square)
                board.arrows = [BoardArrow(from: p.from, to: p.to, colour: BC.coral)]
                board.tints = [w.square: .wrong]
                Feel.warning()
                return
            }
            append(p)
            botTurn(judging: p, fenBefore: before, at: index)
        case .analyse:
            clearHelp()
            append(p)
            if engineMode == .judge { judgeOnly(p, fenBefore: before, at: index) } else { refresh() }
        }
    }

    /// Adds a move after the current one (or follows it if it's already the next move).
    private func append(_ p: Ply, sound: Bool = true) {
        if index < plies.count, plies[index].uci == p.uci {
            index += 1
        } else {
            judged = judged.filter { $0.key <= index }
            plies = Array(plies.prefix(index)) + [p]
            index = plies.count
        }
        if sound { Feel.move(san: p.san) }
        showPosition(animated: true)
    }

    /// The guard warned, you meant it.
    func playAnyway() {
        guard let w = guardWarning else { return }
        clearGuard()
        append(w.ply)
        botTurn(judging: w.ply, fenBefore: w.before, at: index)
    }

    /// The guard warned: take another look.
    func thinkAgain() {
        clearGuard()
        Feel.tick()
    }

    private func clearGuard() {
        guardWarning = nil
        board.arrows = []
        board.tints = [:]
    }

    func play(uci: String) {
        guard mode == .analyse, let p = Chess.play(uci, on: fen) else { return }
        clearHelp()
        append(p)
        refresh()
    }

    func go(to i: Int) {
        guard mode == .analyse, i >= 0, i <= plies.count else { return }
        clearHelp()
        index = i
        showPosition(animated: true)
        refresh()
    }

    func flip() {
        withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.35)) {
            board.flipped.toggle()
            preview.flipped = board.flipped
        }
    }

    /// Start again from a position.
    func reset(fen: String, history: [String] = [], flipped: Bool? = nil) {
        clearHelp()
        work?.cancel()
        root = fen
        plies = Chess.replay(history, from: fen)
        index = plies.count
        judged = [:]
        if let flipped { board.flipped = flipped }
        showPosition(animated: false)
        refresh()
    }

    func resetToStart() {
        if let start { reset(fen: start.fen, history: start.history, flipped: start.flipped) }
        else { reset(fen: Chess.startFEN, flipped: false) }
    }

    func clearMoves() { reset(fen: root) }

    private func clearHelp() {
        lineTask?.cancel()
        playingLine = false
        hint = nil
        retrying = nil
        lineShown = false
    }

    private func showPosition(animated: Bool) {
        let last = index > 0 ? plies[index - 1] : nil
        board.set(fen: fen, lastMove: last.map { MovePair(from: $0.from, to: $0.to) }, animated: animated)
        board.tints = [:]
        board.badge = judged[index].map { BoardBadge(square: $0.ply.to, cls: $0.cls) }
        lines = []
        depth = nil
        board.arrows = []
        if mode == .analyse, engineMode == .lines, let cached = cache[Self.key(fen)] { showLines(cached, for: fen) }
    }

    // MARK: - Engine lines

    func setEngineMode(_ m: EngineMode) {
        guard m != engineMode else { return }
        engineMode = m
        UserDefaults.standard.set(m.rawValue, forKey: "board.engineMode")
        clearHelp()
        showPosition(animated: false)
        refresh()
    }

    /// Starts whatever engine work the current position needs.
    func refresh() {
        guard active else { return }
        let target = fen
        switch mode {
        case .bot:
            guard let g = game, result == nil else { work?.cancel(); stopEngine(); return }
            if Chess.sideToMove(target) == g.side { ponder() } else { botTurn(judging: nil, fenBefore: nil, at: index) }
        case .analyse:
            guard Chess.outcome(target) == .active || Chess.outcome(target) == .check else {
                work?.cancel(); stopEngine(); return
            }
            switch engineMode {
            case .off:
                work?.cancel()
                stopEngine()
            case .judge:
                ponder()
            case .lines:
                let n = max(1, min(5, settings.engineLines))
                let d = min(30, max(12, settings.engineDepth + 4))
                run { [weak self] in
                    try? await Task.sleep(nanoseconds: 90_000_000)
                    guard let self, !Task.isCancelled else { return }
                    let got = await EngineService.shared.analyse(fen: target, depth: d, multipv: n, owner: self.owner) { [weak self] got in
                        guard let self, !Task.isCancelled, self.fen == target, self.mode == .analyse, self.engineMode == .lines else { return }
                        self.store(got, for: target)
                        self.showLines(got, for: target)
                    }
                    self.store(got, for: target)
                }
            }
        }
    }

    /// Quietly analyses the current position so the next verdict is instant.
    private func ponder() {
        let target = fen
        run { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, !Task.isCancelled else { return }
            _ = await self.search(target, depth: 14, accept: 14, multipv: 2)
        }
    }

    private func showLines(_ got: [EngineLine], for target: String) {
        guard let top = got.first else { return }
        bar = (top.cp, top.mate)
        depth = top.depth
        lines = got.prefix(5).map { l in
            ShownLine(id: l.rank, eval: Eval.text(cp: l.cp, mate: l.mate),
                      text: Chess.sanLine(l.pv, from: target, limit: 10).joined(separator: " "), pv: l.pv)
        }
        if settings.moveArrows, let b = top.best, b.count >= 4 {
            board.arrows = [BoardArrow(from: String(b.prefix(2)), to: String(b.dropFirst(2).prefix(2)), colour: BC.violet, opacity: 0.8)]
        } else {
            board.arrows = []
        }
    }

    /// Tap a line: play its first move. Long press: play the whole line.
    func playLine(_ line: ShownLine, whole: Bool) {
        guard mode == .analyse else { return }
        if whole {
            playPlies(Chess.replay(Array(line.pv.prefix(10)), from: fen), interval: 0.42) { }
        } else if let u = line.pv.first {
            play(uci: u)
        }
    }

    private func playPlies(_ line: [Ply], interval: Double, done: @escaping () -> Void) {
        guard !line.isEmpty else { return }
        lineTask?.cancel()
        work?.cancel()
        stopEngine()
        playingLine = true
        lineTask = Task { @MainActor [weak self] in
            for (k, p) in line.enumerated() {
                if k > 0 { try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000)) }
                guard let self, !Task.isCancelled else { return }
                self.append(p)
                if k + 1 < line.count {
                    let n = line[k + 1]
                    self.board.arrows = [BoardArrow(from: n.from, to: n.to, colour: BC.mint, opacity: 0.55)]
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.playingLine = false
            done()
            self.showPosition(animated: false)
            self.refresh()
        }
    }

    // MARK: - Judge

    private func judgeOnly(_ p: Ply, fenBefore: String, at idx: Int) {
        run { [weak self] in
            guard let self else { return }
            if let j = await self.judge(p, before: fenBefore, at: idx) { self.record(j, at: idx) }
        }
    }

    private func record(_ j: Judged, at idx: Int) {
        guard idx <= plies.count, plies[idx - 1].uci == j.ply.uci else { return }
        judged[idx] = j
        if index == idx { board.badge = BoardBadge(square: j.ply.to, cls: j.cls) }
        if j.cls.isError { Feel.wrong() } else if j.cls.isTop { Feel.right() }
    }

    private func judge(_ p: Ply, before fenBefore: String, at idx: Int) async -> Judged? {
        checking = idx
        defer { if checking == idx { checking = nil } }
        await EngineService.shared.stop(owner: owner)
        let b = await search(fenBefore, depth: 14, accept: 12, multipv: 2)
        if Task.isCancelled { return nil }
        let a = await search(p.fenAfter, depth: 14, accept: 12, multipv: 2)
        if Task.isCancelled { return nil }
        let mover = Chess.sideToMove(fenBefore)
        let ctx = Eval.Context(fenBefore: fenBefore, fenAfter: p.fenAfter, mover: mover, played: p.uci, best: b,
                               after: a.first, isBook: isBook(p.uci, fenBefore: fenBefore), opponentLoss: opponentLoss(at: idx - 1))
        let v = Eval.classify(ctx)
        let best = b.first?.best
        let line = Coach.explain(san: p.san, cls: v.cls, theme: v.theme, square: v.square, fenBefore: fenBefore,
                                 fenAfter: p.fenAfter, bestUCI: best, replyUCI: a.first?.best,
                                 opponent: mode == .bot ? "the bot" : "your opponent")
        let pv = b.first?.pv ?? []
        // Coach capitalises the first letter, which turns a pawn move like "f6" into "F6".
        var headline = line.headline
        if headline.lowercased().hasPrefix(p.san.lowercased()), !headline.hasPrefix(p.san) {
            headline = p.san + headline.dropFirst(p.san.count)
        }
        return Judged(ply: p, fenBefore: fenBefore, mover: mover, cls: v.cls, headline: headline, detail: line.detail,
                      best: best, bestSAN: best.flatMap { Chess.play($0, on: fenBefore)?.san }, pv: pv,
                      reply: a.first?.pv ?? [], before: v.before, after: v.after)
    }

    private func isBook(_ uci: String, fenBefore: String) -> Bool {
        for rep in reps {
            if let n = rep.node(fen: fenBefore),
               rep.continuing(n).children.contains(where: { (Chess.play($0.uci, on: fenBefore)?.uci ?? $0.uci) == uci }) {
                return true
            }
        }
        guard let e = book?.entry(fenBefore), let m = e.moves.first(where: { $0.uci == uci }) else { return false }
        return m.games >= 50 && e.share(m) >= 0.03
    }

    /// What the move that reached ply `k` gave away, for its mover. Used to spot a Miss.
    private func opponentLoss(at k: Int) -> Double? {
        guard k >= 1, k <= plies.count else { return nil }
        if let j = judged[k] { return j.loss }
        let before = fen(at: k - 1), after = fen(at: k)
        guard let b = cache[Self.key(before)]?.first, let a = cache[Self.key(after)]?.first else { return nil }
        let mover = Chess.sideToMove(before)
        return max(0, Eval.points(b, for: mover) - Eval.points(a, for: mover))
    }

    /// Stockfish's lines for a position, from the cache when they're deep enough.
    private func search(_ fen: String, depth: Int, accept: Int, multipv: Int) async -> [EngineLine] {
        let key = Self.key(fen)
        let legal = Chess.legalMoveCount(fen)
        guard legal > 0 else { return [] }
        if let c = cache[key], (c.first?.depth ?? 0) >= accept, c.count >= min(multipv, legal) { return c }
        let got = await EngineService.shared.analyse(fen: fen, depth: depth, multipv: multipv, owner: owner)
        store(got, for: fen)
        return got
    }

    private func store(_ got: [EngineLine], for fen: String) {
        guard let top = got.first else { return }
        let key = Self.key(fen)
        if let old = cache[key], let o = old.first {
            let score = { (d: Int, n: Int) in d + 3 * min(n, 3) }
            guard score(top.depth, got.count) >= score(o.depth, old.count) else { return }
        }
        if cache.count > 600 { cache = [:] }
        cache[key] = got
    }

    private static func key(_ fen: String) -> String { fen.split(separator: " ").prefix(4).joined(separator: " ") }

    // MARK: - Help after a verdict (Analyse)

    /// Takes the move back and shows Stockfish's choice.
    func showBest(_ j: Judged, at idx: Int) {
        guard mode == .analyse else { return }
        go(to: idx - 1)
        board.badge = nil
        let pv = j.pv.isEmpty ? (j.best.map { [$0] } ?? []) : j.pv
        guard let b = pv.first, b.count >= 4 else { return }
        hint = BestHint(fen: j.fenBefore, pv: pv, san: j.bestSAN ?? b)
        board.arrows = [BoardArrow(from: String(b.prefix(2)), to: String(b.dropFirst(2).prefix(2)), colour: BC.mint, opacity: 0.85)]
    }

    /// Plays the line that shows why a move works, from the position before it.
    func showWhy(_ j: Judged, at idx: Int) {
        guard mode == .analyse else { return }
        let line = Chess.replay(Array(j.whyLine.prefix(9)), from: j.fenBefore)
        guard !line.isEmpty else { return }
        go(to: idx - 1)
        board.badge = nil
        playPlies(line, interval: 0.8) { [weak self] in self?.lineShown = true }
    }

    func tryAgain(_ j: Judged, at idx: Int) {
        guard mode == .analyse else { return }
        go(to: idx - 1)
        board.badge = nil
        retrying = j
    }

    /// Adds Stockfish's line one move at a time, so you can step back through it.
    func playHintLine() {
        guard let h = hint, h.fen == fen else { return }
        let line = Chess.replay(Array(h.pv.prefix(8)), from: h.fen)
        playPlies(line, interval: 0.8) { [weak self] in
            self?.hint = nil
            self?.lineShown = true
        }
    }

    // MARK: - Bot

    func startBot(choice: SideChoice, elo: Int, opponents: Bool = false) {
        clearHelp()
        work?.cancel()
        stopEngine()
        player.clear()
        showingBest = nil
        showingWhy = false
        botStuck = false
        let side: PieceColor = switch choice {
        case .white: .white
        case .black: .black
        case .random: Bool.random() ? .white : .black
        }
        plies = Array(plies.prefix(index))
        judged = judged.filter { $0.key <= index }
        game = BotGame(side: side, choice: choice, elo: elo, startIndex: index, opponents: opponents)
        result = nil
        botThinking = false
        mode = .bot
        board.bothSides = false
        board.userColor = side
        withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.35)) {
            board.flipped = side == .black
            preview.flipped = board.flipped
        }
        showPosition(animated: false)
        if !checkGameOver() { refresh() }
    }

    func rematch() {
        guard let g = game else { return }
        plies = Array(plies.prefix(g.startIndex))
        index = plies.count
        startBot(choice: g.choice, elo: g.elo, opponents: g.opponents)
    }

    /// Back to Analyse, keeping every move (and its mark).
    func analyse() {
        guard mode == .bot else { return }
        work?.cancel()
        stopEngine()
        player.clear()
        showingBest = nil
        showingWhy = false
        botStuck = false
        botThinking = false
        game = nil
        result = nil
        mode = .analyse
        board.bothSides = true
        board.userColor = nil
        index = plies.count
        showPosition(animated: false)
        refresh()
    }

    func takeBack() {
        guard let g = game, result == nil, canTakeBack else { return }
        work?.cancel()
        stopEngine()
        player.clear()
        showingBest = nil
        showingWhy = false
        botStuck = false
        botThinking = false
        var j = plies.count
        while j > g.startIndex {
            let mover = Chess.sideToMove(fen(at: j - 1))
            j -= 1
            if mover == g.side { break }
        }
        plies = Array(plies.prefix(j))
        index = j
        judged = judged.filter { $0.key <= j }
        Feel.tick()
        showPosition(animated: true)
        refresh()
    }

    func resign() {
        guard game != nil, result == nil else { return }
        work?.cancel()
        stopEngine()
        finish(.loss, reason: "You resigned")
    }

    /// Shows the best move and its line on a copy of the board.
    func showBotBest() {
        guard let j = lastBotVerdict?.judged, !j.wasBest else { return }
        let pv = j.pv.isEmpty ? (j.best.map { [$0] } ?? []) : j.pv
        guard !pv.isEmpty else { return }
        preview.flipped = board.flipped
        preview.set(fen: j.fenBefore, lastMove: nil, animated: false)
        showingWhy = false
        withAnimation(BC.curve(0.3)) { showingBest = j }
        player.play(pv, from: j.fenBefore, on: preview, colour: BC.mint, limit: 8)
    }

    /// Why your move works, on a copy of the board.
    func showBotWhy() {
        guard let j = lastBotVerdict?.judged, j.hasWhy else { return }
        preview.flipped = board.flipped
        preview.set(fen: j.fenBefore, lastMove: nil, animated: false)
        showingWhy = true
        withAnimation(BC.curve(0.3)) { showingBest = j }
        player.play(j.whyLine, from: j.fenBefore, on: preview, colour: j.cls.colour, limit: 9)
    }

    func closeBotBest() {
        player.clear()
        withAnimation(BC.curve(0.3)) { showingBest = nil }
        showingWhy = false
    }

    /// Ask the bot again after it couldn't find a move.
    func retryBot() {
        guard let g = game, result == nil, Chess.sideToMove(fen) != g.side else { botStuck = false; return }
        botStuck = false
        botTurn(judging: nil, fenBefore: nil, at: index)
    }

    /// The bot's turn: mark your move first, then answer it.
    private func botTurn(judging p: Ply?, fenBefore: String?, at idx: Int) {
        guard let g = game, result == nil else { return }
        botThinking = Chess.sideToMove(fen) != g.side
        run { [weak self] in
            guard let self else { return }
            let started = Date()
            if let p, let fenBefore {
                if let j = await self.judge(p, before: fenBefore, at: idx) { self.record(j, at: idx) }
                if Task.isCancelled { return }
            }
            if self.checkGameOver() { return }
            let target = self.fen
            guard Chess.sideToMove(target) != g.side else { self.botThinking = false; return }
            self.botThinking = true
            self.botStuck = false
            var pick = await self.botPick(fen: target, elo: g.elo)
            if Task.isCancelled { return }
            if pick.flatMap({ Chess.play($0, on: target) }) == nil, self.fen == target {
                // The engine came back empty: one more go before giving up.
                pick = await self.botPick(fen: target, elo: g.elo)
                if Task.isCancelled { return }
            }
            let wait = 0.55 - Date().timeIntervalSince(started)
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            while self.showingBest != nil, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            guard !Task.isCancelled, self.fen == target else {
                if !Task.isCancelled { self.botThinking = false }
                return
            }
            guard let pick, let ply = Chess.play(pick, on: target) else {
                // Never leave it looking like your turn while the bot should move.
                self.botThinking = false
                self.botStuck = true
                return
            }
            self.botThinking = false
            self.append(ply)
            if self.checkGameOver() { return }
            _ = await self.search(self.fen, depth: 14, accept: 14, multipv: 2)
        }
    }

    /// Human-like strength: club moves from the book while it lasts, then Stockfish with room for error.
    private func botPick(fen: String, elo: Int) async -> String? {
        if game?.opponents == true, let u = opponentBook?.pick(fen), let ply = Chess.play(u, on: fen) {
            return ply.uci
        }
        if elo < 1800, let book, let e = book.entry(fen), e.games >= 30,
           let m = book.humanMove(fen, minGames: 30), let ply = Chess.play(m.uci, on: fen) {
            return ply.uci
        }
        let t = Double(min(2800, max(400, elo)) - 400) / 2400
        let depth = 2 + Int((t * 16).rounded())
        let tolerance = 30 * pow(1 - t, 1.5)
        let got = await EngineService.shared.analyse(fen: fen, depth: depth, multipv: 3, owner: owner)
        if Task.isCancelled { return nil }
        guard let top = got.first else { return nil }
        let side = Chess.sideToMove(fen)
        if let m = Eval.mateFor(top, side), m > 0 { return top.best }
        let topWin = Eval.win(cp: top.cp, mate: top.mate, for: side)
        let ok = got.filter { $0.best != nil && topWin - Eval.win(cp: $0.cp, mate: $0.mate, for: side) <= tolerance }
        guard !ok.isEmpty else { return top.best }
        let weights = ok.indices.map { [1.0, 0.75, 0.55][min($0, 2)] }
        var r = Double.random(in: 0..<weights.reduce(0, +))
        for (i, w) in weights.enumerated() {
            r -= w
            if r < 0 { return ok[i].best }
        }
        return top.best
    }

    @discardableResult
    private func checkGameOver() -> Bool {
        guard let g = game else { return false }
        if result != nil { return true }
        switch Chess.outcome(fen) {
        case .checkmate(let w):
            finish(w == g.side ? .win : .loss, reason: w == g.side ? "You won by checkmate" : "Checkmated by the bot")
        case .draw(let r):
            finish(.draw, reason: "Draw by \(Self.drawReason(r).lowercased())")
        default:
            return false
        }
        return true
    }

    private func finish(_ kind: GameResult.Kind, reason: String) {
        guard let g = game else { return }
        let mine = judged.filter { $0.key > g.startIndex && $0.value.mover == g.side }.map(\.value)
        var counts: [MoveClass: Int] = [:]
        for j in mine { counts[j.cls == .forced ? .good : j.cls, default: 0] += 1 }
        let acc = mine.isEmpty ? nil : mine.map(\.accuracy).reduce(0, +) / Double(mine.count)
        let moves = (g.startIndex..<plies.count).filter { Chess.sideToMove(fen(at: $0)) == g.side }.count
        result = GameResult(kind: kind, reason: reason, accuracy: acc, counts: counts, moves: moves)
        botThinking = false
        botStuck = false
        board.userColor = nil
        switch kind {
        case .win: Feel.complete()
        case .loss: Feel.lost()
        case .draw: Feel.next()
        }
        gameOverCount += 1
    }

    static func drawReason(_ raw: String) -> String {
        let r = raw.lowercased()
        if r.contains("stale") { return "Stalemate" }
        if r.contains("insufficient") { return "Insufficient material" }
        if r.contains("fifty") || r.contains("50") { return "Fifty-move rule" }
        if r.contains("repet") { return "Repetition" }
        return "Agreement"
    }

    static func eloLabel(_ elo: Int) -> String {
        switch elo {
        case ..<700: "Beginner"
        case ..<1000: "Casual player"
        case ..<1400: "Club player"
        case ..<1800: "Strong club player"
        case ..<2200: "Expert"
        case ..<2500: "Master"
        default: "Grandmaster"
        }
    }

    // MARK: - Plumbing

    private func run(_ body: @escaping @MainActor () async -> Void) {
        work?.cancel()
        work = Task { @MainActor in await body() }
    }
}
