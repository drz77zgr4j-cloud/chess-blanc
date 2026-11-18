import Foundation

/// Plain-English explanations of a move, built only from what Stockfish and the board actually show.
enum Coach {
    struct Line {
        let headline: String      // "Nxe5 is a blunder"
        let detail: String        // "It leaves your knight on e5 to be taken. Best was d4."
    }

    static func explain(san: String, cls: MoveClass, theme: Eval.Theme?, square: String?, fenBefore: String,
                        fenAfter: String, bestUCI: String?, replyUCI: String?, opponent: String = "your opponent") -> Line {
        let bestSAN = bestUCI.flatMap { Chess.play($0, on: fenBefore)?.san }
        let reply = replyUCI.flatMap { Chess.play($0, on: fenAfter)?.san }
        let head = "\(san) is \(cls.phrase)"
        let pieceAt: (String?) -> String = { sq in
            guard let sq, let i = Board64.index(sq), let c = Board64(fen: fenAfter).piece(i) else { return "piece" }
            return Board64.pieceName(c)
        }
        let better = bestSAN.map { " Best was \($0)." } ?? ""
        switch (cls, theme) {
        case (.brilliant, _):
            let b = Board64(fen: fenAfter)
            let white = !b.whiteToMove
            let sac = b.unsafePieces(white: white).compactMap { b.piece($0) }.max { Board64.value($0) < Board64.value($1) }
            return Line(headline: "\(san) is brilliant", detail: "You give up your \(sac.map(Board64.pieceName) ?? "piece"). It's a real sacrifice — and it works.")
        case (.great, _):
            return Line(headline: "\(san) is the only move", detail: "The only good move here. Everything else gave a lot away.")
        case (.best, _):
            return Line(headline: "\(san) is best", detail: "Exactly what Stockfish would play.")
        case (.book, _):
            return Line(headline: "\(san) is theory", detail: "A well-known opening move.")
        case (.forced, _):
            return Line(headline: "\(san) was forced", detail: "The only legal move.")
        case (.excellent, _), (.good, _):
            return Line(headline: head, detail: bestSAN.map { "\($0) was a little stronger." } ?? "A solid move.")
        case (_, .hungPiece?):
            return Line(headline: head, detail: "It leaves your \(pieceAt(square)) on \(square ?? "the board") to be taken" + (reply.map { " (\($0))." } ?? ".") + better)
        case (_, .allowedMate?):
            return Line(headline: head, detail: "It lets \(opponent) force checkmate" + (reply.map { ", starting with \($0)." } ?? ".") + better)
        case (_, .missedMate?):
            return Line(headline: head, detail: "You had a forced mate" + (bestSAN.map { " starting with \($0)." } ?? "."))
        case (_, .missedWin?):
            return Line(headline: "\(san) is a missed chance", detail: "Your opponent had just slipped." + (bestSAN.map { " \($0) would have punished it." } ?? ""))
        case (_, .lostMaterial?):
            return Line(headline: head, detail: "You come out material down" + (reply.map { " after \($0)." } ?? ".") + better)
        default:
            return Line(headline: head, detail: cls == .inaccuracy ? "Not a disaster, but it gives some of your edge away." + better
                        : "It hands your opponent the better game." + better)
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
