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
    private var job: Job?
    private var busy = false
    private var waiters: [Waiter] = []
    /// The newest request per owner. An older request from the same owner that is still waiting gives up.
    private var tickets: [String: Int] = [:]

    private struct Waiter {
        let owner: String?
        let continuation: CheckedContinuation<Void, Never>
    }
    private var preparing: Task<Void, Never>?

    private var lastUserActivity = Date.distantPast

    final class Job {
        let whiteToMove: Bool
        let background: Bool
        let onUpdate: (([EngineLine]) -> Void)?
        var lines: [Int: EngineLine] = [:]
        var continuation: CheckedContinuation<[EngineLine], Never>?
        var cancelled = false
        var lastPush = Date.distantPast
        var owner: String?
        init(whiteToMove: Bool, background: Bool, onUpdate: (([EngineLine]) -> Void)?) {
            self.whiteToMove = whiteToMove
            self.background = background
            self.onUpdate = onUpdate
        }
        var sorted: [EngineLine] { lines.values.sorted { $0.rank < $1.rank } }
    }

    func prepare() async {
        if isReady { return }
        if let preparing { await preparing.value; return }
        let task = Task { @MainActor in
            let e = Engine(type: .stockfish)
            self.engine = e
            let cores = max(2, ProcessInfo.processInfo.activeProcessorCount - 1)
            await e.start(coreCount: cores, multipv: 1)
            if let stream = await e.responseStream {
                self.listener = Task { @MainActor [weak self] in
                    for await r in stream { self?.handle(r) }
                }
            }
            for _ in 0..<200 {
                if await e.isRunning { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            await e.send(command: .setoption(id: "Hash", value: "64"))
            self.isReady = true
        }
        preparing = task
        await task.value
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
        guard let engine, let clean = Self.safeFEN(fen) else { return [] }
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
        await engine.send(command: .setoption(id: "MultiPV", value: "\(multipv)"))
        await engine.send(command: .position(.fen(clean)))
        // Safety net: never wait forever.
        let watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(8, depth)) * 1_500_000_000)
            if self?.job === j { await self?.engine?.send(command: .stop) }
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

    private func handle(_ r: EngineResponse) {
        guard let j = job else { return }
        switch r {
        case let .info(info):
            guard let pv = info.pv, !pv.isEmpty, let score = info.score,
                  score.lowerbound != true, score.upperbound != true else { return }
            let rank = info.multipv ?? 1
            var cp = score.cp
            var mate = score.mate
            if !j.whiteToMove { cp = cp.map { -$0 }; mate = mate.map { -$0 } }
            j.lines[rank] = EngineLine(rank: rank, cp: mate == nil ? cp : nil, mate: mate, depth: info.depth ?? 0, pv: pv)
            if !j.cancelled, let push = j.onUpdate, Date().timeIntervalSince(j.lastPush) > 0.15 {
                j.lastPush = Date()
                push(j.sorted)
            }
        case .bestmove:
            let result = j.sorted
            if !j.cancelled { j.onUpdate?(result) }
            job = nil
            busy = false
            j.continuation?.resume(returning: result)
            j.continuation = nil
            if !waiters.isEmpty { waiters.removeFirst().continuation.resume() }
        default:
            break
        }
    }

    /// Stockfish aborts the whole app on a FEN that doesn't match its board (castling rights with no rook,
    /// a bad en-passant square, a missing king). Clean every FEN before it gets there.
    nonisolated static func safeFEN(_ fen: String) -> String? {
        var parts = fen.split(separator: " ").map(String.init)
        guard parts.count >= 1 else { return nil }
        while parts.count < 6 { parts.append(["w", "-", "-", "0", "1"][parts.count - 1]) }
        // Expand the board into 64 squares, a8 first.
        var squares: [Character] = []
        for ch in parts[0] {
            if ch == "/" { continue }
            if let n = ch.wholeNumberValue { squares += Array(repeating: ".", count: n) } else { squares.append(ch) }
        }
        guard squares.count == 64, squares.filter({ $0 == "K" }).count == 1, squares.filter({ $0 == "k" }).count == 1 else {
            return nil
        }
        func at(_ sq: String) -> Character {
            let f = Int(sq.unicodeScalars.first!.value) - 97, r = Int(String(sq.last!))!
            return squares[(8 - r) * 8 + f]
        }
        if parts[1] != "w" && parts[1] != "b" { parts[1] = "w" }
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
