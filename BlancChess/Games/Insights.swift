import SwiftUI

/// One way you lose points, measured on your own reviewed games.
struct Weakness: Identifiable {
    enum Kind: String, CaseIterable {
        case hanging, missedChances, allowedMate, losingMaterial, timeTrouble, leftPrep, conversion, drifting
    }
    let kind: Kind
    let count: Int              // how many times
    let games: Int              // in how many games
    let pointsLost: Double      // expected points given away in total
    let examples: [Puzzle]      // positions to train it on, worst first
    var id: String { kind.rawValue }

    var title: String {
        switch kind {
        case .hanging: "You leave pieces hanging"
        case .missedChances: "You miss their mistakes"
        case .allowedMate: "You walk into mates"
        case .losingMaterial: "You lose material in exchanges"
        case .timeTrouble: "You crack under time pressure"
        case .leftPrep: "You leave your opening prep"
        case .conversion: "You don't convert winning games"
        case .drifting: "Quiet moves that drift"
        }
    }

    var why: String {
        switch kind {
        case .hanging: "After your move, a piece can simply be taken. It's the most common way club games are lost."
        case .missedChances: "Your opponent blundered and you played on as if nothing happened. Free points left on the board."
        case .allowedMate: "Your move let them force checkmate. It usually comes from not checking their checks and captures."
        case .losingMaterial: "A trade or capture that comes out a pawn or more behind once the dust settles."
        case .timeTrouble: "Most of these slips came with under 30 seconds on your clock."
        case .leftPrep: "You played a different move from your repertoire in the opening."
        case .conversion: "You were clearly winning and the game ended in a draw or a loss."
        case .drifting: "No tactic, just a move that lets their position improve. These add up."
        }
    }

    var how: String {
        switch kind {
        case .hanging: "Before every move, ask: what can they take after this? Train on your own positions below."
        case .missedChances: "After every opponent move, look for checks, captures and threats first."
        case .allowedMate: "Check every check they could give after your move. Train on the positions below."
        case .losingMaterial: "Count attackers and defenders before you capture. Recalculate after every trade."
        case .timeTrouble: "Spend less time early. Play your prep fast so you bank time for the middlegame."
        case .leftPrep: "The repertoire moves you missed come first in your opening practice. Or train them on the positions below."
        case .conversion: "When ahead: trade pieces, not pawns, keep your king safe, push the passed pawn."
        case .drifting: "Look for your worst piece and improve it. Ask what your opponent wants."
        }
    }

    var icon: String {
        switch kind {
        case .hanging: "exclamationmark.triangle.fill"
        case .missedChances: "eye.slash.fill"
        case .allowedMate: "crown.fill"
        case .losingMaterial: "arrow.left.arrow.right"
        case .timeTrouble: "timer"
        case .leftPrep: "book.closed.fill"
        case .conversion: "flag.slash.fill"
        case .drifting: "water.waves"
        }
    }

    /// Short line for a row: "12 times in 9 games".
    var summary: String { "\(count) time\(count == 1 ? "" : "s") in \(games) game\(games == 1 ? "" : "s")" }
}

/// Where a game left your repertoire.
struct PrepMatch {
    let repertoire: Repertoire
    let pliesInBook: Int
    let leftAt: Int?
    let leftByYou: Bool
    /// Your repertoire move at the point you left.
    let expected: RepNode?
    /// The last repertoire position the game reached.
    let lastNode: RepNode?
}

extension GameRecord {
    func prep(in reps: [Repertoire]) -> PrepMatch? {
        guard startFEN == Chess.startFEN, let rep = reps.first(where: { $0.color == userColor }) else { return nil }
        let fens = FenCache.shared.fens(self)
        var last: RepNode? = rep.root
        for i in 0..<min(ucis.count, fens.count - 1) {
            if let n = rep.node(fen: fens[i + 1]) {
                last = n
                continue
            }
            let mine = moverAt(i) == userColor
            let expected = last.flatMap { rep.myMove(after: $0) }
            // Only count as "you left" if your repertoire actually had a move here.
            return PrepMatch(repertoire: rep, pliesInBook: i, leftAt: i, leftByYou: mine && expected != nil,
                             expected: mine ? expected : nil, lastNode: last)
        }
        return PrepMatch(repertoire: rep, pliesInBook: ucis.count, leftAt: nil, leftByYou: false, expected: nil, lastNode: last)
    }

    /// Expected points the mover gave away with each ply, from stored evals.
    func losses() -> [Double] {
        guard let r = review else { return [] }
        var out: [Double] = []
        for i in 0..<r.evals.count {
            let mover = moverAt(i)
            let beforeCP = i == 0 ? 30.0 : r.evals[i - 1]
            let before = Eval.win(cp: beforeCP, mate: nil, for: mover) / 100
            let after = Eval.win(cp: r.evals[i], mate: nil, for: mover) / 100
            out.append(max(0, before - after))
        }
        return out
    }
}

enum Insights {
    /// Your weaknesses, costliest first.
    static func weaknesses(games: [GameRecord], reps: [Repertoire]) -> [Weakness] {
        var buckets: [Weakness.Kind: (count: Int, games: Set<String>, lost: Double, ex: [(Double, Puzzle)])] = [:]
        func add(_ k: Weakness.Kind, _ g: GameRecord, _ loss: Double, _ p: Puzzle?) {
            var b = buckets[k] ?? (0, [], 0, [])
            b.count += 1
            b.games.insert(g.id)
            b.lost += loss
            if let p { b.ex.append((loss, p)) }
            buckets[k] = b
        }
        for g in games {
            guard let r = g.review else { continue }
            let fens = FenCache.shared.fens(g)
            let losses = g.losses()
            for (i, c) in r.classes.enumerated() where g.moverAt(i) == g.userColor && c.isSlip {
                guard i < fens.count, i < losses.count else { continue }
                let theme = r.themes?[safe: i] ?? nil
                let p = puzzle(g, r, i, fens)
                let loss = losses[i]
                switch theme {
                case .hungPiece: add(.hanging, g, loss, p)
                case .allowedMate: add(.allowedMate, g, loss, p)
                case .missedMate, .missedWin: add(.missedChances, g, loss, p)
                case .lostMaterial: add(.losingMaterial, g, loss, p)
                default: if c != .inaccuracy || loss > 0.06 { add(.drifting, g, loss, p) }
                }
                if let clocks = g.clocks, i < clocks.count, clocks[i] < 30, c.isError {
                    add(.timeTrouble, g, loss, p)
                }
            }
            // Thrown wins: you reached a clearly winning position and didn't win.
            if g.result != .win {
                let best = r.evals.map { Eval.win(cp: $0, mate: nil, for: g.userColor) }.max() ?? 0
                if best >= 85 { add(.conversion, g, (best - (g.result == .draw ? 50 : 0)) / 100, nil) }
            }
            if let m = g.prep(in: reps), m.leftByYou, let at = m.leftAt, let exp = m.expected, at < fens.count {
                let p = Puzzle(id: "\(g.id)#\(at)", gameID: g.id, fen: fens[at], best: exp.uci, bestLine: [exp.uci],
                               played: g.ucis[at], cls: .book, ply: at, opponent: g.opponent, date: g.endTime,
                               phase: .opening, kind: .fix, theme: nil,
                               prompt: "Your repertoire move here.")
                add(.leftPrep, g, losses[safe: at] ?? 0.03, p)
            }
        }
        return buckets.map { k, b in
            Weakness(kind: k, count: b.count, games: b.games.count, pointsLost: b.lost,
                     examples: b.ex.sorted { $0.0 > $1.0 }.map(\.1))
        }
        .filter { $0.count >= 2 }
        // "Drifting" is the catch-all for quiet slips: real, but not actionable on its own, so it ranks last.
        .sorted { ($0.kind == .drifting ? 0 : 1, $0.pointsLost) > ($1.kind == .drifting ? 0 : 1, $1.pointsLost) }
    }

    /// Every slip you made, as a position to fix.
    static func mistakes(games: [GameRecord]) -> [Puzzle] {
        var out: [Puzzle] = []
        for g in games {
            guard let r = g.review else { continue }
            let fens = FenCache.shared.fens(g)
            for (i, c) in r.classes.enumerated() where g.moverAt(i) == g.userColor && [.mistake, .miss, .blunder].contains(c) {
                if let p = puzzle(g, r, i, fens) { out.append(p) }
            }
        }
        return out
    }

    /// Chances from your games: punishing their mistakes, and great moves (yours and theirs) to find.
    static func challenges(games: [GameRecord]) -> [Puzzle] {
        var out: [Puzzle] = []
        for g in games {
            guard let r = g.review else { continue }
            let fens = FenCache.shared.fens(g)
            for (i, c) in r.classes.enumerated() where i < fens.count && i < r.best.count && !r.best[i].isEmpty {
                let mine = g.moverAt(i) == g.userColor
                let theyErred = i > 0 && g.moverAt(i - 1) != g.userColor && [.mistake, .blunder].contains(r.classes[i - 1])
                var kind: Puzzle.Kind? = nil
                var prompt = ""
                if mine && theyErred { kind = .punish; prompt = "\(g.opponent) just blundered. Punish it." }
                else if mine && (c == .brilliant || c == .great) { kind = .findAgain; prompt = "You found a \(c.title.lowercased()) move here. Find it again." }
                else if !mine && (c == .brilliant || c == .great) { kind = .theirs; prompt = "\(g.opponent) found a \(c.title.lowercased()) move against you. Can you?" }
                guard let kind else { continue }
                out.append(Puzzle(id: "c-\(g.id)#\(i)", gameID: g.id, fen: fens[i], best: r.best[i],
                                  bestLine: r.bestLines[safe: i] ?? [r.best[i]], played: "", cls: c, ply: i,
                                  opponent: g.opponent, date: g.endTime, phase: Phase.of(fen: fens[i], ply: i),
                                  kind: kind, prompt: prompt))
            }
        }
        return out
    }

    private static func puzzle(_ g: GameRecord, _ r: GameReview, _ i: Int, _ fens: [String]) -> Puzzle? {
        guard i < fens.count, i < r.best.count, !r.best[i].isEmpty, r.best[i] != g.ucis[i] else { return nil }
        return Puzzle(id: "\(g.id)#\(i)", gameID: g.id, fen: fens[i], best: r.best[i],
                      bestLine: r.bestLines[safe: i] ?? [r.best[i]], played: g.ucis[i], cls: r.classes[i], ply: i,
                      opponent: g.opponent, date: g.endTime, phase: Phase.of(fen: fens[i], ply: i),
                      kind: .fix, theme: r.themes?[safe: i] ?? nil, prompt: "")
    }

    /// Where your slips happen, per game.
    static func phaseRates(games: [GameRecord]) -> [(Phase, Double)] {
        var counts: [Phase: Int] = [:]
        var n = 0
        for g in games {
            guard let r = g.review else { continue }
            n += 1
            let fens = FenCache.shared.fens(g)
            for (i, c) in r.classes.enumerated() where g.moverAt(i) == g.userColor && c.isError && i < fens.count {
                counts[Phase.of(fen: fens[i], ply: i), default: 0] += 1
            }
        }
        return Phase.allCases.map { ($0, n == 0 ? 0 : Double(counts[$0] ?? 0) / Double(n)) }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
