import Foundation

/// The bot-game safety net: before a move is played, does it hang a piece or allow mate in one?
/// Instant (no engine): the attack map, plus every reply that gives check.
enum BlunderGuard {
    struct Warning { let text: String; let square: String }

    static func warning(before: String, ply: Ply) -> Warning? {
        let me = Chess.sideToMove(before)
        let white = me == .white
        let after = ply.fenAfter
        if case .checkmate = Chess.outcome(after) { return nil }

        // Mate in one: only replies that give check can be mate.
        for u in Chess.legalUCIs(after) {
            guard let r = Chess.play(u, on: after), Chess.inCheck(r.fenAfter) else { continue }
            if case .checkmate = Chess.outcome(r.fenAfter) {
                return Warning(text: "That lets them mate with \(Chess.numbered(r.san, fenBefore: after)).",
                               square: Board64.name(Board64(fen: after).kingSquare(white: white) ?? 0))
            }
        }
        // A check leaves them no time to take anything.
        if Chess.inCheck(after) { return nil }

        let b0 = Board64(fen: before)
        let b1 = Board64(fen: after)
        let captured = Board64.index(ply.to).flatMap { b0.piece($0) }.map(Board64.value) ?? 0
        // Their pieces left hanging too: then it's a trade of threats, not a blunder.
        let theirs = b1.unsafePieces(white: !white).compactMap { b1.piece($0) }.map(Board64.value).max() ?? 0
        let worst = b1.unsafePieces(white: white)
            .compactMap { i -> (Int, Character)? in b1.piece(i).map { (i, $0) } }
            .max { Board64.value($0.1) < Board64.value($1.1) }
        guard let (sq, piece) = worst else { return nil }
        let v = Board64.value(piece)
        guard v > captured, v > theirs else { return nil }
        return Warning(text: "That leaves your \(Board64.pieceName(piece)) on \(Board64.name(sq)) hanging.", square: Board64.name(sq))
    }
}
