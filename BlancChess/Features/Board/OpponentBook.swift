import Foundation

/// The opening moves your chess.com opponents play against you, by position. Games you lost count double,
/// so the bot steers into the lines that beat you most.
struct OpponentBook: Sendable {
    private let moves: [String: [String: Int]]

    /// Works through your games' first 24 plies off the main thread.
    static func build(_ games: [GameRecord]) async -> OpponentBook {
        await Task.detached(priority: .userInitiated) {
            var m: [String: [String: Int]] = [:]
            for g in games where g.startFEN == Chess.startFEN {
                let fens = FenCache.shared.fens(g)
                let weight = g.result == .loss ? 2 : 1
                for i in 0..<min(24, g.ucis.count, fens.count) where g.moverAt(i) != g.userColor {
                    m[Repertoire.key(fens[i]), default: [:]][g.ucis[i], default: 0] += weight
                }
            }
            return OpponentBook(moves: m)
        }.value
    }

    /// A move they've played here, picked by how often they played it.
    func pick(_ fen: String) -> String? {
        guard let counts = moves[Repertoire.key(fen)], !counts.isEmpty else { return nil }
        var r = Int.random(in: 0..<counts.values.reduce(0, +))
        for (u, n) in counts.sorted(by: { $0.key < $1.key }) {
            r -= n
            if r < 0 { return u }
        }
        return counts.first?.key
    }
}
