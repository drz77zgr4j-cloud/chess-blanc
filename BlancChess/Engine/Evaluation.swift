import Foundation

/// Evaluation maths and chess.com-style move classification (Classification V2, expected points).
///
/// Thresholds are chess.com's published expected-points bands. Brilliant / Great / Miss follow the closest
/// open reimplementation (WintrChess): a real piece sacrifice that is the best move and doesn't come from an
/// already-won position; Great = the only good move; Miss = not punishing the opponent's mistake.
enum Eval {
    /// Win chance 0…100 for White (Lichess model).
    static func whiteWin(cp: Double?, mate: Int?) -> Double {
        if let mate { return mate > 0 ? 100 : 0 }
        let c = max(-1500, min(1500, cp ?? 0))
        return 50 + 50 * (2 / (1 + exp(-0.00368208 * c)) - 1)
    }

    static func win(cp: Double?, mate: Int?, for color: PieceColor) -> Double {
        let w = whiteWin(cp: cp, mate: mate)
        return color == .white ? w : 100 - w
    }

    /// Expected points 0…1 for one side.
    static func points(_ line: EngineLine?, for color: PieceColor) -> Double {
        guard let line else { return 0.5 }
        return win(cp: line.cp, mate: line.mate, for: color) / 100
    }

    static func whiteShare(cp: Double?, mate: Int?) -> Double {
        min(0.97, max(0.03, whiteWin(cp: cp, mate: mate) / 100))
    }

    static func text(cp: Double?, mate: Int?) -> String {
        if let mate { return mate > 0 ? "M\(mate)" : "-M\(abs(mate))" }
        return String(format: "%+.1f", (cp ?? 0) / 100)
    }

    /// Accuracy of one move from the win chance it gave away (Lichess formula), 0…100.
    static func moveAccuracy(winBefore: Double, winAfter: Double) -> Double {
        let loss = max(0, winBefore - winAfter)
        return max(0, min(100, 103.1668 * exp(-0.04354 * loss) - 3.1669))
    }

    /// Centipawns from one side's point of view (mate = ±10000).
    static func cp(_ line: EngineLine?, for color: PieceColor) -> Double {
        guard let line else { return 0 }
        if let m = line.mate { return (m > 0) == (color == .white) ? 10000 : -10000 }
        let c = line.cp ?? 0
        return color == .white ? c : -c
    }

    static func mateFor(_ line: EngineLine?, _ color: PieceColor) -> Int? {
        guard let m = line?.mate else { return nil }
        // engine mate is from White's side: positive = White mates
        let forMover = color == .white ? m : -m
        return forMover
    }

    // MARK: Classification

    struct Context {
        let fenBefore: String
        let fenAfter: String
        let mover: PieceColor
        let played: String              // uci
        let best: [EngineLine]          // MultiPV lines before the move (best first)
        let after: EngineLine?          // best line from the position after the move (opponent to move)
        let isBook: Bool
        let opponentLoss: Double?       // expected points the opponent gave away on their last move
        /// The opponent's previous move (uci), so recaptures aren't called "great".
        var previous: String? = nil
    }

    enum Theme: String, Codable {
        case hungPiece, allowedMate, missedMate, missedWin, lostMaterial, sacrifice, onlyMove, positional
    }

    struct Verdict {
        var cls: MoveClass
        let before: Double              // expected points before, mover's view
        let after: Double               // expected points after
        var loss: Double { max(0, before - after) }
        var theme: Theme? = nil
        var square: String? = nil       // the square the theme is about (a hanging piece, say)
    }

    static func classify(_ c: Context) -> Verdict {
        let me = c.mover
        guard let top = c.best.first else { return Verdict(cls: .good, before: 0.5, after: 0.5) }
        let before = points(top, for: me)
        let afterLine = c.after
        let after = afterLine.map { points($0, for: me) } ?? before

        if Chess.legalMoveCount(c.fenBefore) == 1 { return Verdict(cls: .forced, before: before, after: after) }
        if case .checkmate = Chess.outcome(c.fenAfter) { return Verdict(cls: .best, before: before, after: 1) }
        let loss = max(0, before - after)
        if c.isBook && loss < 0.05 { return Verdict(cls: .book, before: before, after: after) }

        let isTop = top.best == c.played
        let topMate = mateFor(top, me)
        let afterMate = mateFor(afterLine, me)
        var v = Verdict(cls: .best, before: before, after: after)

        if !isTop {
            if let am = afterMate, am < 0, (topMate ?? 1) > 0 {
                // You now get mated.
                v.cls = -am <= 2 ? .blunder : -am <= 5 ? .mistake : .inaccuracy
                v.theme = .allowedMate
            } else if let tm = topMate, tm > 0, (afterMate ?? 0) <= 0 {
                // You had a forced mate and let it go.
                let cpAfter = cp(afterLine, for: me)
                v.cls = cpAfter >= 800 ? .excellent : cpAfter >= 400 ? .good : cpAfter >= 200 ? .inaccuracy : cpAfter >= 0 ? .mistake : .blunder
                v.theme = .missedMate
            } else if let am = afterMate, am > 0 {
                v.cls = loss < 0.02 ? .excellent : .good
            } else {
                v.cls = loss < 0.02 ? .excellent : loss < 0.05 ? .good : loss < 0.10 ? .inaccuracy : loss < 0.20 ? .mistake : .blunder
            }
        }

        // What the slip actually cost.
        if v.cls.isSlip, v.theme == nil {
            if let hung = hangsPiece(c) {
                v.theme = .hungPiece
                v.square = hung
            } else if losesMaterial(c) {
                v.theme = .lostMaterial
            } else {
                v.theme = .positional
            }
        }
        // chess.com: a blunder loses material or allows mate; otherwise it's a mistake.
        if v.cls == .blunder, ![.hungPiece, .lostMaterial, .allowedMate, .missedMate].contains(v.theme) {
            v.cls = .mistake
        }
        // Miss: the opponent just erred, you had a winning shot, and you let it go.
        if [.mistake, .blunder, .inaccuracy].contains(v.cls), let ol = c.opponentLoss, ol >= 0.10,
           before >= 0.75, after < 0.70, v.theme != .hungPiece, v.theme != .allowedMate {
            v.cls = .miss
            v.theme = .missedWin
        }

        // Great and Brilliant are only for the top move, from a position that isn't already won.
        guard isTop, gatePasses(c, top: top) else { return v }
        if let second = c.best.dropFirst().first, topMate == nil || topMate! <= 0 {
            let p2 = points(second, for: me)
            if before - p2 >= 0.10 && !capturesFreePiece(c) && !isRecapture(c) {
                v.cls = .great
                v.theme = .onlyMove
            }
        }
        if isSacrifice(c) {
            v.cls = .brilliant
            v.theme = .sacrifice
        }
        return v
    }

    /// Not already completely winning, not losing after, not a promotion, not escaping check.
    private static func gatePasses(_ c: Context, top: EngineLine) -> Bool {
        let me = c.mover
        if let second = c.best.dropFirst().first, cp(second, for: me) >= 700 { return false }
        if c.best.count < 2, cp(top, for: me) >= 700 { return false }
        if cp(c.after, for: me) < 0 { return false }
        if c.played.count > 4 { return false }   // promotions
        if Chess.inCheck(c.fenBefore) { return false }
        return true
    }

    /// A real sacrifice: after the move one of your pieces (knight or more) can be won and is worth more than
    /// what the move captured — and taking it doesn't just give the material straight back.
    static func isSacrifice(_ c: Context) -> Bool {
        let white = c.mover == .white
        let b0 = Board64(fen: c.fenBefore)
        let b1 = Board64(fen: c.fenAfter)
        let captured = Board64.index(String(c.played.dropFirst(2).prefix(2))).flatMap { b0.piece($0) }.map(Board64.value) ?? 0
        let unsafeAfter = b1.unsafePieces(white: white)
        let unsafeBefore = b0.unsafePieces(white: white)
        guard let biggest = unsafeAfter.compactMap({ b1.piece($0) }).map(Board64.value).max(), biggest > captured else { return false }
        let givesCheck = Chess.inCheck(c.fenAfter)
        if unsafeAfter.count < unsafeBefore.count && !givesCheck { return false }
        // If the opponent's best reply takes, make sure we don't simply take back the same.
        guard let pv = c.after?.pv, let reply = pv.first else { return true }
        let replyTarget = Board64.index(String(reply.dropFirst(2).prefix(2)))
        guard let t = replyTarget, unsafeAfter.contains(t) else { return true }   // declined: still a sac
        let before = b0.material(white: white)
        var fen = c.fenAfter
        for u in pv.prefix(2) {
            guard let p = Chess.play(u, on: fen) else { break }
            fen = p.fenAfter
        }
        return before - Board64(fen: fen).material(white: white) >= 2
    }

    /// Taking back on the square they just captured on is obvious, not great.
    private static func isRecapture(_ c: Context) -> Bool {
        guard let prev = c.previous, prev.count >= 4 else { return false }
        let to = String(c.played.dropFirst(2).prefix(2))
        return to == String(prev.dropFirst(2).prefix(2)) && Board64(fen: c.fenBefore).piece(Board64.index(to) ?? 0) != nil
    }

    private static func capturesFreePiece(_ c: Context) -> Bool {
        let b0 = Board64(fen: c.fenBefore)
        guard let t = Board64.index(String(c.played.dropFirst(2).prefix(2))), let victim = b0.piece(t) else { return false }
        return b0.attackers(of: t, white: Board64.isWhite(victim)).isEmpty
    }

    /// The square of a piece the move leaves to be taken, if the opponent's best reply takes it.
    static func hangsPiece(_ c: Context) -> String? {
        guard let reply = c.after?.pv.first else { return nil }
        let b1 = Board64(fen: c.fenAfter)
        guard let t = Board64.index(String(reply.dropFirst(2).prefix(2))), let victim = b1.piece(t),
              Board64.isWhite(victim) == (c.mover == .white), Board64.value(victim) >= 3, b1.isUnsafe(t) else { return nil }
        return Board64.name(t)
    }

    /// Material down by 2+ after the best reply and your best answer.
    static func losesMaterial(_ c: Context) -> Bool {
        guard let pv = c.after?.pv, !pv.isEmpty else { return false }
        let white = c.mover == .white
        let before = Board64(fen: c.fenBefore).material(white: white)
        var fen = c.fenAfter
        for u in pv.prefix(2) {
            guard let p = Chess.play(u, on: fen) else { break }
            fen = p.fenAfter
        }
        return before - Board64(fen: fen).material(white: white) >= 2
    }
}
