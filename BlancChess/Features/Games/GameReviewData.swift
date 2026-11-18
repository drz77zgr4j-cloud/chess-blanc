import SwiftUI

/// Everything the review screen derives from one game, worked out once (positions, labels, counts, key moments).
struct GameReviewData {
    let fens: [String]
    let ucis: [String]
    let sans: [String]
    /// "12.Nf3" for White's moves, "Nf6" for Black's (strip labels).
    let stripLabels: [String]
    /// "12.Nf3" / "12…Nf6".
    let numbered: [String]
    let movers: [PieceColor]
    let userColor: PieceColor
    /// Only a review in the current format counts.
    let review: GameReview?
    let mine: [MoveClass: Int]
    let theirs: [MoveClass: Int]
    /// Plies worth stopping at: your slips, brilliant and great moves, and where the game left book.
    let keyPlies: [Int]
    let bookExit: Int?
    let prep: PrepMatch?

    var plies: Int { min(ucis.count, fens.count - 1) }
    var ready: Bool { review != nil }

    init(game g: GameRecord, reps: [Repertoire], previous: GameReviewData? = nil) {
        let fens = previous?.fens ?? FenCache.shared.fens(g)
        self.fens = fens
        let n = min(g.ucis.count, fens.count - 1)
        ucis = Array(g.ucis.prefix(n))
        sans = Array(g.sans.prefix(n))
        userColor = g.userColor
        movers = (0..<n).map { g.moverAt($0) }
        var strip: [String] = [], num: [String] = []
        for i in 0..<n {
            let san = i < g.sans.count ? g.sans[i] : g.ucis[i]
            let white = Chess.sideToMove(fens[i]) == .white
            let mv = Chess.moveNumber(fens[i])
            num.append(white ? "\(mv).\(san)" : "\(mv)…\(san)")
            strip.append(white ? "\(mv).\(san)" : (i == 0 ? "\(mv)…\(san)" : san))
        }
        stripLabels = strip
        numbered = num
        prep = previous?.prep ?? g.prep(in: reps)

        let r = g.review?.version == GameReview.currentVersion ? g.review : nil
        review = r
        var mine: [MoveClass: Int] = [:], theirs: [MoveClass: Int] = [:]
        var keys: [Int] = []
        var exit: Int? = nil
        if let r {
            for (i, c) in r.classes.prefix(n).enumerated() {
                let isMine = movers[i] == g.userColor
                if isMine { mine[c, default: 0] += 1 } else { theirs[c, default: 0] += 1 }
                if isMine && (c.isSlip || c == .brilliant || c == .great) { keys.append(i) }
                if exit == nil && c != .book { exit = i }
            }
            if let e = exit, e > 0, !keys.contains(e) { keys.append(e) } else if exit == 0 { exit = nil }
        }
        self.mine = mine
        self.theirs = theirs
        keyPlies = keys.sorted()
        bookExit = exit
    }

    // MARK: Per-move helpers

    func cls(_ i: Int) -> MoveClass? { review?.classes[safe: i] }

    func move(_ i: Int) -> MovePair {
        MovePair(from: String(ucis[i].prefix(2)), to: String(ucis[i].dropFirst(2).prefix(2)))
    }

    /// The engine's best move before ply i, if it differs from what was played and the mark says it mattered.
    func betterMove(_ i: Int) -> String? {
        guard let r = review, let c = cls(i), let b = r.best[safe: i], b.count >= 4, b != ucis[i] else { return nil }
        if [.book, .forced, .best, .brilliant, .great].contains(c) { return nil }
        return b
    }

    /// Your plies with this mark.
    func hits(_ c: MoveClass) -> [Int] {
        guard let r = review else { return [] }
        return r.classes.prefix(plies).enumerated().filter { movers[$0.offset] == userColor && $0.element == c }.map(\.offset)
    }

    /// White-side evaluation at position k (0 = start). Mates are recovered from the stored line when it's short.
    func eval(at k: Int) -> (cp: Double?, mate: Int?) {
        guard let r = review else { return (20, nil) }
        // The reviewer stores 0 for a mated final position; the side that mated has won.
        if k > 0, k <= plies, sans[k - 1].hasSuffix("#") { return (movers[k - 1] == .white ? 1500 : -1500, nil) }
        let e = k == 0 ? 20 : (r.evals[safe: k - 1] ?? 0)
        if abs(e) >= 1500, let pv = r.bestLines[safe: k], !pv.isEmpty, pv.count < 12 {
            return (nil, (e > 0 ? 1 : -1) * ((pv.count + 1) / 2))
        }
        return (e, nil)
    }

    func evalText(at k: Int) -> String {
        let e = eval(at: k)
        return Eval.text(cp: e.cp, mate: e.mate)
    }

    /// The coach's words for ply i, from the mover's point of view.
    func coach(_ i: Int, opponent: String) -> Coach.Line? {
        guard let r = review, let c = cls(i) else { return nil }
        let isMine = movers[i] == userColor
        let theme = (r.themes?[safe: i]) ?? nil
        let square = (r.squares?[safe: i]) ?? nil
        let best = r.best[safe: i].flatMap { $0.isEmpty ? nil : $0 }
        let reply = r.bestLines[safe: i + 1]?.first
        let line = Coach.explain(san: sans[i], cls: c, theme: theme, square: square, fenBefore: fens[i], fenAfter: fens[i + 1],
                                 bestUCI: best, replyUCI: reply, opponent: isMine ? opponent : "you")
        var detail = line.detail.replacingOccurrences(of: "Tap Show why", with: "Tap Why it's brilliant")
        if !isMine { detail = Self.theirView(detail) }
        // Coach capitalises the first letter, which turns pawn moves into "C3"; keep SAN as written.
        var headline = line.headline
        let shouted = sans[i].capitalizedFirst
        if shouted != sans[i], headline.hasPrefix(shouted) { headline = sans[i] + headline.dropFirst(shouted.count) }
        return Coach.Line(headline: headline, detail: detail)
    }

    /// Coach writes to you about your own move; for the opponent's moves, turn it round.
    static func theirView(_ s: String) -> String {
        var t = s
        let swaps = [("Your opponent had just slipped.", "You had just slipped."), ("You give up your", "They give up their"),
                     ("You had a forced mate", "They had a forced mate"), ("You come out", "They come out"),
                     ("your ", "their "), ("Your ", "Their ")]
        for (a, b) in swaps { t = t.replacingOccurrences(of: a, with: b) }
        return t
    }

    /// One sentence for where the game left your repertoire.
    var prepText: String? {
        guard let p = prep else { return nil }
        guard let at = p.leftAt, at < plies else { return "You stayed in your repertoire the whole game." }
        if p.leftByYou, let exp = p.expected {
            return "You left your repertoire with \(numbered[at]). Your move there is \(exp.numbered)."
        }
        if movers[at] == userColor {
            return "Your repertoire had no move here. You played \(numbered[at])."
        }
        return "They left your repertoire with \(numbered[at])."
    }
}
