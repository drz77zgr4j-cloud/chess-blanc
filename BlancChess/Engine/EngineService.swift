import Foundation
import ChessKitEngine

/// One engine line. Scores are from White's side of the board.
struct EngineLine: Identifiable, Equatable {
    let rank: Int
    var cp: Double?
    var mate: Int?
    var depth: Int
    var pv: [String]
    var id: Int { rank }
    var best: String? { pv.first }
}

/// Stockfish 17 on the phone. One search at a time; a new request stops the previous one.
@MainActor
final class EngineService: ObservableObject {
    static let shared = EngineService()

    @Published private(set) var isReady = false

    private var engine: Engine?
    private var listener: Task<Void, Never>?
    private var job: Job? { didSet { current.set(job) } }
    /// The running job, readable off the main actor: Stockfish's `info` lines are parsed on the listener's thread.
    private nonisolated let current = JobBox()
    private var busy = false
    private var waiters: [Waiter] = []
    /// The newest request per owner. An older request from the same owner that is still waiting gives up.
    private var tickets: [String: Int] = [:]
    /// Jobs given up on by the watchdog: their late `bestmove` (if it ever comes) must not end the next job.
    private var staleBestmoves = 0

    /// Search threads: everything but one core for what you're looking at, at most two for background reviews.
    private let foregroundThreads = max(1, ProcessInfo.processInfo.activeProcessorCount - 2)
    private var backgroundThreads: Int { min(2, foregroundThreads) }
    private var threads = 0

    private struct Waiter {
        let owner: String?
        let continuation: CheckedContinuation<Void, Never>
    }
    private var preparing: Task<Void, Never>?

    private var lastUserActivity = Date.distantPast

    final class Job: @unchecked Sendable {
        let whiteToMove: Bool
        let background: Bool
        /// Called on the main actor.
        let onUpdate: (([EngineLine]) -> Void)?
        /// Main actor only.
        var continuation: CheckedContinuation<[EngineLine], Never>?
        var owner: String?

        private let lock = NSLock()
        private var lines: [Int: EngineLine] = [:]
        private var stopped = false
        private var lastPush = Date.distantPast

        init(whiteToMove: Bool, background: Bool, onUpdate: (([EngineLine]) -> Void)?) {
            self.whiteToMove = whiteToMove
            self.background = background
            self.onUpdate = onUpdate
        }

        var cancelled: Bool {
            get { lock.withLock { stopped } }
            set { lock.withLock { stopped = newValue } }
        }
        var sorted: [EngineLine] { lock.withLock { lines.values.sorted { $0.rank < $1.rank } } }
        var hasLines: Bool { lock.withLock { !lines.isEmpty } }

        /// Records one line (any thread). Returns the lines to show when a throttled update is due.
        func ingest(_ line: EngineLine) -> [EngineLine]? {
            lock.withLock {
                lines[line.rank] = line
                guard !stopped, onUpdate != nil, Date().timeIntervalSince(lastPush) > 0.15 else { return nil }
                lastPush = Date()
                return lines.values.sorted { $0.rank < $1.rank }
            }
        }
    }

    final class JobBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Job?
        var job: Job? { lock.withLock { value } }
        func set(_ j: Job?) { lock.withLock { value = j } }
    }

    func prepare() async {
        if isReady { return }
        if let preparing { await preparing.value; return }
        let task = Task { @MainActor in
            let e = Engine(type: .stockfish)
            self.engine = e
            // ChessKitEngine sets Threads to coreCount - 1.
            await e.start(coreCount: self.foregroundThreads + 1, multipv: 1)
            self.threads = self.foregroundThreads
            if let stream = await e.responseStream {
                let box = self.current
                // Info lines arrive many times a second: parse them here, off the main actor, and only hop
                // to it for a throttled update or the final answer.
                self.listener = Task.detached(priority: .userInitiated) { [weak self] in
                    for await r in stream {
                        switch r {
                        case let .info(info):
                            guard let j = box.job, let line = Self.line(info, whiteToMove: j.whiteToMove),
                                  let push = j.ingest(line) else { continue }
                            await MainActor.run { [weak self] in
                                guard let self, self.job === j, !j.cancelled else { return }
                                j.onUpdate?(push)
                            }
                        case .bestmove:
                            await MainActor.run { [weak self] in self?.engineAnswered() }
                        default:
                            break
                        }
                    }
                }
            }
            for _ in 0..<200 {
                if await e.isRunning { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            await self.markReadyIfRunning()
        }
        preparing = task
        await task.value
    }

    /// The engine finished its setup: size the hash and open for work. If it never does, jobs return nothing
    /// instead of waiting forever.
    private func markReadyIfRunning() async {
        guard !isReady, let e = engine, await e.isRunning else { return }
        await e.send(command: .setoption(id: "Hash", value: "32"))
        isReady = true
    }

    /// The engine started and answers; game reviews check this so a dead engine doesn't produce empty reviews.
    var usable: Bool { isReady }

    nonisolated private static func line(_ info: EngineResponse.Info, whiteToMove: Bool) -> EngineLine? {
        guard let pv = info.pv, !pv.isEmpty, let score = info.score,
              score.lowerbound != true, score.upperbound != true else { return nil }
        let rank = info.multipv ?? 1
        var cp = score.cp
        var mate = score.mate
        if !whiteToMove { cp = cp.map { -$0 }; mate = mate.map { -$0 } }
        return EngineLine(rank: rank, cp: mate == nil ? cp : nil, mate: mate, depth: info.depth ?? 0, pv: pv)
    }

    /// Analyse a position to `depth`. `onUpdate` streams improving lines while it thinks.
    @discardableResult
    func analyse(fen: String, depth: Int = 18, multipv: Int = 1, background: Bool = false, owner: String? = nil,
                 onUpdate: (([EngineLine]) -> Void)? = nil) async -> [EngineLine] {
        // Take a ticket first: a newer request from the same owner makes this one stale.
        var ticket = 0
        if let owner {
            ticket = (tickets[owner] ?? 0) + 1
            tickets[owner] = ticket
            // Anything older from this owner that is still queued returns [] right away instead of running.
            let stale = waiters.filter { $0.owner == owner }
            waiters.removeAll { $0.owner == owner }
            for w in stale { w.continuation.resume() }
        }
        func superseded() -> Bool { owner.map { tickets[$0] != ticket } ?? false }

        await prepare()
        if !isReady { await markReadyIfRunning() }
        guard isReady, let engine, let clean = Self.safeFEN(fen) else { return [] }
        if superseded() { return [] }
        if background {
            // Game reviews wait while you are using the engine yourself.
            while (job.map { !$0.background } ?? false) || Date().timeIntervalSince(lastUserActivity) < 2.5 {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled || superseded() { return [] }
            }
        } else {
            lastUserActivity = Date()
        }
        if let current = job {
            current.cancelled = true
            await engine.send(command: .stop)
        }
        while busy {
            await withCheckedContinuation { waiters.append(Waiter(owner: owner, continuation: $0)) }
            if superseded() {
                // Hand the turn on if it was given to us.
                if !busy, !waiters.isEmpty { waiters.removeFirst().continuation.resume() }
                return []
            }
        }
        if superseded() {
            if !waiters.isEmpty { waiters.removeFirst().continuation.resume() }
            return []
        }
        busy = true
        let j = Job(whiteToMove: Chess.sideToMove(fen) == .white, background: background, onUpdate: onUpdate)
        j.owner = owner
        job = j
        // Background reviews share the phone: a couple of threads. What you're looking at gets the rest.
        let want = background ? backgroundThreads : foregroundThreads
        if want != threads {
            threads = want
            await engine.send(command: .setoption(id: "Threads", value: "\(want)"))
        }
        await engine.send(command: .setoption(id: "MultiPV", value: "\(multipv)"))
        await engine.send(command: .position(.fen(clean)))
        // Safety net: never wait forever. Ask Stockfish to stop; if it still doesn't answer, give up on it
        // with what it has, so the next search can run.
        let watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(8, depth)) * 1_500_000_000)
            guard !Task.isCancelled, let self, self.job === j else { return }
            await self.engine?.send(command: .stop)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, self.job === j else { return }
            self.staleBestmoves += 1
            self.finish(j)
        }
        let result = await withCheckedContinuation { (c: CheckedContinuation<[EngineLine], Never>) in
            j.continuation = c
            Task { await engine.send(command: .go(depth: depth)) }
        }
        watchdog.cancel()
        return result
    }

    /// Stops the current search only if it belongs to `owner` (so leaving one screen can't stop the next one's search).
    func stop(owner: String) async {
        guard let job, job.owner == owner, let engine else { return }
        job.cancelled = true
        await engine.send(command: .stop)
    }

    func stop() async {
        guard let job, let engine else { return }
        job.cancelled = true
        await engine.send(command: .stop)
    }

    /// Stockfish's `bestmove`: the current search is over.
    private func engineAnswered() {
        guard let j = job else {
            if staleBestmoves > 0 { staleBestmoves -= 1 }
            return
        }
        if staleBestmoves > 0 {
            staleBestmoves -= 1
            // A late answer to a search the watchdog already gave up on: this job hasn't heard anything yet.
            if !j.hasLines { return }
        }
        finish(j)
    }

    /// Hands a job its lines and gives the engine to the next one waiting.
    private func finish(_ j: Job) {
        guard job === j else { return }
        let result = j.sorted
        if !j.cancelled { j.onUpdate?(result) }
        job = nil
        busy = false
        j.continuation?.resume(returning: result)
        j.continuation = nil
        if !waiters.isEmpty { waiters.removeFirst().continuation.resume() }
    }

    /// Stockfish aborts the whole app on a FEN that doesn't match its board (castling rights with no rook,
    /// a bad en-passant square, a missing king). Clean every FEN before it gets there.
    nonisolated static func safeFEN(_ fen: String) -> String? {
        var parts = fen.split(separator: " ").map(String.init)
        guard parts.count >= 1 else { return nil }
        while parts.count < 6 { parts.append(["w", "-", "-", "0", "1"][parts.count - 1]) }
        // Strictly: 8 ranks of exactly 8 squares, known characters only (nothing else ever reaches Stockfish's
        // input, which takes positions as text), one king each, no pawns on the back ranks.
        let ranks = parts[0].split(separator: "/", omittingEmptySubsequences: false)
        guard ranks.count == 8 else { return nil }
        var squares: [Character] = []
        for rank in ranks {
            var width = 0
            for ch in rank {
                if let n = ch.wholeNumberValue, (1...8).contains(n) {
                    width += n; squares += Array(repeating: ".", count: n)
                } else if "pnbrqkPNBRQK".contains(ch) {
                    width += 1; squares.append(ch)
                } else { return nil }
            }
            guard width == 8 else { return nil }
        }
        guard squares.count == 64, squares.filter({ $0 == "K" }).count == 1, squares.filter({ $0 == "k" }).count == 1,
              !squares[0..<8].contains(where: { $0 == "p" || $0 == "P" }),
              !squares[56..<64].contains(where: { $0 == "p" || $0 == "P" }) else {
            return nil
        }
        func at(_ sq: String) -> Character {
            let f = Int(sq.unicodeScalars.first!.value) - 97, r = Int(String(sq.last!))!
            return squares[(8 - r) * 8 + f]
        }
        if parts[1] != "w" && parts[1] != "b" { parts[1] = "w" }
        // The side that isn't to move must not be in check (its king could be captured: Stockfish can't take that).
        do {
            let b = Board64(fen: parts[0] + " " + parts[1])
            let notToMoveIsWhite = !b.whiteToMove
            if let k = b.kingSquare(white: notToMoveIsWhite), !b.attackers(of: k, white: !notToMoveIsWhite).isEmpty { return nil }
        }
        var rights = ""
        for c in parts[2] {
            switch c {
            case "K" where at("e1") == "K" && at("h1") == "R": rights.append(c)
            case "Q" where at("e1") == "K" && at("a1") == "R": rights.append(c)
            case "k" where at("e8") == "k" && at("h8") == "r": rights.append(c)
            case "q" where at("e8") == "k" && at("a8") == "r": rights.append(c)
            default: break
            }
        }
        parts[2] = rights.isEmpty ? "-" : rights
        let ep = parts[3]
        if ep != "-" {
            let ok = ep.count == 2 && "abcdefgh".contains(ep.first!) && ep.last == (parts[1] == "w" ? "6" : "3")
            if !ok { parts[3] = "-" }
        }
        if Int(parts[4]) == nil { parts[4] = "0" }
        if (Int(parts[5]) ?? 0) < 1 { parts[5] = "1" }
        return parts.prefix(6).joined(separator: " ")
    }
}
