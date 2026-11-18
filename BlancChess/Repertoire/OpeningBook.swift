import Foundation

/// What club players play, offline: 1.5 million rated Lichess games (1000–1900, blitz and slower),
/// counted by Tools/build_explorer.py and exported by Tools/build_book.py.
final class OpeningBook {
    struct Move: Identifiable, Hashable {
        let uci: String
        let san: String
        let white: Int
        let draws: Int
        let black: Int
        var id: String { uci }
        var games: Int { white + draws + black }
    }

    struct Entry {
        let moves: [Move]
        var games: Int { moves.reduce(0) { $0 + $1.games } }
        func share(_ m: Move) -> Double { games == 0 ? 0 : Double(m.games) / Double(games) }
    }

    private let positions: [String: [[Any]]]
    private let names: [String: String]

    private init(positions: [String: [[Any]]], names: [String: String]) {
        self.positions = positions
        self.names = names
    }

    static func load() async -> OpeningBook? {
        await Task.detached(priority: .utility) {
            guard let url = Bundle.main.url(forResource: "book", withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pos = obj["positions"] as? [String: [[Any]]] else { return nil }
            // The file keys positions by placement, side and castling; the app keys by placement and side.
            func short(_ k: String) -> String { k.split(separator: " ").prefix(2).joined(separator: " ") }
            var p2: [String: [[Any]]] = [:]
            for (k, v) in pos where p2[short(k)] == nil { p2[short(k)] = v }
            var n2: [String: String] = [:]
            for (k, v) in obj["names"] as? [String: String] ?? [:] where n2[short(k)] == nil { n2[short(k)] = v }
            return OpeningBook(positions: p2, names: n2)
        }.value
    }

    /// The moves played from this position, most common first.
    func entry(_ fen: String) -> Entry? {
        guard let rows = positions[Repertoire.key(fen)] else { return nil }
        let moves = rows.compactMap { r -> Move? in
            guard r.count == 5, let u = r[0] as? String, let s = r[1] as? String,
                  let w = r[2] as? Int, let d = r[3] as? Int, let b = r[4] as? Int else { return nil }
            return Move(uci: Self.castle(u, san: s), san: s, white: w, draws: d, black: b)
        }
        return moves.isEmpty ? nil : Entry(moves: moves)
    }

    /// The opening's name at this position, if it has one.
    func name(_ fen: String) -> String? { names[Repertoire.key(fen)] }

    /// A move picked the way a club player would: weighted by how often it's played.
    func humanMove(_ fen: String, minGames: Int = 8) -> Move? {
        guard let e = entry(fen), e.games >= minGames else { return nil }
        var r = Int.random(in: 0..<max(1, e.games))
        for m in e.moves {
            r -= m.games
            if r < 0 { return m }
        }
        return e.moves.first
    }

    /// python-chess writes castling as the king's target square already; keep Lichess-style just in case.
    private static func castle(_ uci: String, san: String) -> String {
        guard san.hasPrefix("O-O") else { return uci }
        return ["e1h1": "e1g1", "e1a1": "e1c1", "e8h8": "e8g8", "e8a8": "e8c8"][uci] ?? uci
    }
}
