import Foundation

/// Lichess's open API: your games as newline-delimited JSON. Only the username is needed; nothing is posted.
enum Lichess {
    private struct User: Decodable { let username: String }
    private struct Player: Decodable {
        struct U: Decodable { let name: String }
        let user: U?
        let rating: Int?
    }
    private struct Opening: Decodable { let name: String? }
    private struct RawGame: Decodable {
        let id: String
        let rated: Bool?
        let variant: String?
        let speed: String?
        let lastMoveAt: Double?
        let createdAt: Double?
        let status: String?
        let winner: String?
        let players: [String: Player]
        let opening: Opening?
        let moves: String?
        let initialFen: String?
        let clocks: [Int]?
    }

    private static func request(_ url: URL, accept: String) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(accept, forHTTPHeaderField: "Accept")
        r.setValue(Net.userAgent, forHTTPHeaderField: "User-Agent")
        r.timeoutInterval = 60
        return r
    }

    /// The proper spelling of a username, or nil if there's no such player.
    static func user(_ name: String) async throws -> String? {
        guard let n = Net.username(name), let url = URL(string: "https://lichess.org/api/user/\(n)") else { return nil }
        let (data, resp) = try await Net.session.data(for: request(url, accept: "application/json"))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return nil }
        guard code == 200 else { throw ChessCom.Failure.network("Lichess answered \(code). Try again in a minute.") }
        return try JSONDecoder().decode(User.self, from: data).username
    }

    /// Standard games since a date (newest first), already turned into the app's game records.
    static func games(_ name: String, since: Date, known: Set<String>, max: Int = 400) async throws -> [GameRecord] {
        guard let n = Net.username(name) else { return [] }
        let ms = Int(since.timeIntervalSince1970 * 1000)
        guard let url = URL(string: "https://lichess.org/api/games/user/\(n)?since=\(ms)&max=\(max)&moves=true&clocks=true&opening=true&perfType=bullet,blitz,rapid,classical") else { return [] }
        let (data, resp) = try await Net.session.data(for: request(url, accept: "application/x-ndjson"))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw ChessCom.Failure.network("Couldn't reach Lichess.") }
        guard data.count <= Net.maxBytes else { throw ChessCom.Failure.network("Lichess sent more than the app can read.") }
        let decoder = JSONDecoder()
        var out: [GameRecord] = []
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            guard let raw = try? decoder.decode(RawGame.self, from: Data(line)),
                  (raw.variant ?? "standard") == "standard",
                  !known.contains("li-" + raw.id),
                  let g = convert(raw, user: n) else { continue }
            out.append(g)
        }
        return out
    }

    private static func convert(_ raw: RawGame, user: String) -> GameRecord? {
        guard let w = raw.players["white"], let b = raw.players["black"], let moves = raw.moves, !moves.isEmpty else { return nil }
        let wName = w.user?.name ?? "Anonymous", bName = b.user?.name ?? "Anonymous"
        let isWhite = wName.lowercased() == user
        guard isWhite || bName.lowercased() == user else { return nil }
        let result: GameResult
        if let winner = raw.winner { result = (winner == "white") == isWhite ? .win : .loss } else { result = .draw }
        let start = raw.initialFen ?? Chess.startFEN
        guard EngineService.safeFEN(start) != nil else { return nil }
        var fen = start
        var ucis: [String] = [], sans: [String] = []
        for san in moves.split(separator: " ").map(String.init) {
            guard let u = Chess.uci(fromSAN: san, fen: fen), let p = Chess.play(u, on: fen) else { break }
            ucis.append(p.uci); sans.append(p.san); fen = p.fenAfter
        }
        guard !ucis.isEmpty else { return nil }
        let opening = raw.opening?.name ?? "Unknown opening"
        let ended = (raw.lastMoveAt ?? raw.createdAt ?? 0) / 1000
        let speed = raw.speed == "classical" ? "rapid" : (raw.speed ?? "rapid")
        // Lichess clocks are centiseconds left after each move.
        let clocks = raw.clocks.map { $0.map { Double($0) / 100 } }
        return GameRecord(
            id: "li-" + raw.id, url: "https://lichess.org/" + raw.id, endTime: Date(timeIntervalSince1970: ended),
            timeClass: speed, rated: raw.rated ?? true,
            white: wName, whiteRating: w.rating ?? 1500, black: bName, blackRating: b.rating ?? 1500,
            userColor: isWhite ? .white : .black, result: result, resultDetail: raw.status ?? "",
            opening: opening, family: PGN.family(of: opening), startFEN: start,
            ucis: ucis, sans: sans, chessComAccuracy: nil, review: nil, clocks: clocks)
    }
}
