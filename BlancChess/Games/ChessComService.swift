import Foundation

/// chess.com's public, read-only API. Only the username is needed; nothing is ever posted.
enum ChessCom {
    struct Profile: Codable { let username: String; let joined: Double?; let avatar: String?; let name: String? }

    struct Stats: Codable {
        struct Rating: Codable { let rating: Int; let date: Double? }
        struct Record: Codable { let win: Int; let loss: Int; let draw: Int }
        struct Mode: Codable { let last: Rating?; let best: Rating?; let record: Record? }
        struct Tactics: Codable { let highest: Rating? }
        let chess_rapid: Mode?
        let chess_blitz: Mode?
        let chess_bullet: Mode?
        let chess_daily: Mode?
        let tactics: Tactics?
    }

    private struct Archives: Codable { let archives: [String] }
    private struct Side: Codable { let username: String; let rating: Int; let result: String }
    private struct Accuracies: Codable { let white: Double?; let black: Double? }
    private struct RawGame: Codable {
        let url: String
        let pgn: String?
        let end_time: Double
        let rated: Bool?
        let time_class: String?
        let rules: String?
        let white: Side
        let black: Side
        let accuracies: Accuracies?
        let eco: String?
        let initial_setup: String?
    }
    private struct Month: Codable { let games: [RawGame] }

    enum Failure: LocalizedError {
        case notFound, network(String)
        var errorDescription: String? {
            switch self {
            case .notFound: "No chess.com player with that username."
            case .network(let s): s
            }
        }
    }

    private static func get<T: Decodable>(_ url: String, as: T.Type) async throws -> T {
        guard let u = URL(string: url) else { throw Failure.network("Bad address") }
        var req = URLRequest(url: u)
        req.setValue("BlancChess/1.0 (personal training app)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 30
        // Phones drop connections when you switch apps or change networks: try up to three times.
        var attempt = 0
        while true {
            attempt += 1
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 404 { throw Failure.notFound }
                if (code == 429 || code >= 500), attempt < 3 {
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000)
                    continue
                }
                guard code == 200 else { throw Failure.network("chess.com answered \(code). Try again in a minute.") }
                return try JSONDecoder().decode(T.self, from: data)
            } catch let e as URLError where attempt < 3 && e.code != .cancelled {
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
            }
        }
    }

    static func profile(_ user: String) async throws -> Profile {
        try await get("https://api.chess.com/pub/player/\(user.lowercased())", as: Profile.self)
    }

    static func stats(_ user: String) async throws -> Stats {
        try await get("https://api.chess.com/pub/player/\(user.lowercased())/stats", as: Stats.self)
    }

    /// Games from the last `months` monthly archives, newest first.
    static func games(_ user: String, months: Int, known: Set<String>,
                      progress: @escaping (String) -> Void) async throws -> [GameRecord] {
        let list = try await get("https://api.chess.com/pub/player/\(user.lowercased())/games/archives", as: Archives.self)
        // months == 0 means all time. One extra archive covers "the last 30 days" across a month boundary.
        let all = list.archives
        let wanted = months <= 0 ? Array(all) : Array(all.suffix(months + 1))
        // Finished months never change, so each is only downloaded once.
        let doneKey = "archivesDone.\(user.lowercased())"
        var done = Set(UserDefaults.standard.stringArray(forKey: doneKey) ?? [])
        let latest = Set(all.suffix(1))
        let recent = wanted.filter { !done.contains($0) || latest.contains($0) }
        var out: [GameRecord] = []
        for (i, url) in recent.reversed().enumerated() {
            await MainActor.run { progress("Fetching month \(i + 1) of \(recent.count)…") }
            let month = try await get(url, as: Month.self)
            for raw in month.games where (raw.rules ?? "chess") == "chess" && !known.contains(raw.url) {
                if let g = convert(raw, user: user) { out.append(g) }
            }
            if !latest.contains(url) { done.insert(url) }
        }
        UserDefaults.standard.set(Array(done), forKey: doneKey)
        return out.sorted { $0.endTime > $1.endTime }
    }

    private static func convert(_ raw: RawGame, user: String) -> GameRecord? {
        guard let pgn = raw.pgn else { return nil }
        let headers = PGN.headers(pgn)
        let isWhite = raw.white.username.lowercased() == user.lowercased()
        let me = isWhite ? raw.white : raw.black
        let result: GameResult
        switch me.result {
        case "win": result = .win
        case "agreed", "repetition", "stalemate", "insufficient", "50move", "timevsinsufficient": result = .draw
        default: result = .loss
        }
        let detail = (isWhite ? raw.black : raw.white).result == "win" ? me.result : (isWhite ? raw.black.result : raw.white.result)
        let start = raw.initial_setup.flatMap { $0.isEmpty ? nil : $0 } ?? headers["FEN"] ?? Chess.startFEN
        var fen = start
        var ucis: [String] = []
        var sans: [String] = []
        for san in PGN.sanMoves(pgn) {
            guard let u = Chess.uci(fromSAN: san, fen: fen), let p = Chess.play(u, on: fen) else { break }
            ucis.append(p.uci)
            sans.append(p.san)
            fen = p.fenAfter
        }
        let opening = PGN.openingName(ecoURL: headers["ECOUrl"] ?? raw.eco)
        let clocks = PGN.clocks(pgn)
        let acc = isWhite ? raw.accuracies?.white : raw.accuracies?.black
        return GameRecord(
            id: raw.url, url: raw.url, endTime: Date(timeIntervalSince1970: raw.end_time),
            timeClass: raw.time_class ?? "rapid", rated: raw.rated ?? true,
            white: raw.white.username, whiteRating: raw.white.rating,
            black: raw.black.username, blackRating: raw.black.rating,
            userColor: isWhite ? .white : .black, result: result, resultDetail: detail,
            opening: opening, family: PGN.family(of: opening), startFEN: start,
            ucis: ucis, sans: sans, chessComAccuracy: acc, review: nil, clocks: clocks.isEmpty ? nil : clocks)
    }
}
