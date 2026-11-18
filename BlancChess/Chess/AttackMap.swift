import Foundation

/// A light board model for tactics: who attacks which square, which pieces hang, what a move captures.
/// Works straight from a FEN so the classifier and coach can reason without the full rules engine.
struct Board64 {
    /// 0 = a1 … 63 = h8. Uppercase = White.
    private(set) var cells: [Character?]
    let whiteToMove: Bool

    init(fen: String) {
        cells = Array(repeating: nil, count: 64)
        let parts = fen.split(separator: " ")
        whiteToMove = parts.count < 2 || parts[1] == "w"
        var rank = 7, file = 0
        for ch in parts.first ?? "" {
            if ch == "/" { rank -= 1; file = 0; continue }
            if let n = ch.wholeNumberValue { file += n; continue }
            if rank >= 0, file < 8 { cells[rank * 8 + file] = ch }
            file += 1
        }
    }

    static func index(_ sq: String) -> Int? {
        guard sq.count == 2, let f = sq.unicodeScalars.first?.value, let r = Int(String(sq.last!)) else { return nil }
        let file = Int(f) - 97
        guard (0..<8).contains(file), (1...8).contains(r) else { return nil }
        return (r - 1) * 8 + file
    }

    static func name(_ i: Int) -> String {
        "\(Character(UnicodeScalar(97 + i % 8)!))\(i / 8 + 1)"
    }

    func piece(_ i: Int) -> Character? { cells[i] }
    static func isWhite(_ c: Character) -> Bool { c.isUppercase }

    static func value(_ c: Character) -> Int {
        switch c.lowercased() { case "p": 1; case "n", "b": 3; case "r": 5; case "q": 9; case "k": 100; default: 0 }
    }

    static func pieceName(_ c: Character) -> String {
        switch c.lowercased() { case "p": "pawn"; case "n": "knight"; case "b": "bishop"; case "r": "rook"; case "q": "queen"; default: "king" }
    }

    /// Squares of pieces of `white`'s colour that attack square `t`.
    func attackers(of t: Int, white: Bool) -> [Int] {
        var out: [Int] = []
        let tf = t % 8, tr = t / 8
        for (i, c) in cells.enumerated() {
            guard let c, Board64.isWhite(c) == white else { continue }
            let f = i % 8, r = i / 8
            let df = tf - f, dr = tr - r
            switch c.lowercased() {
            case "p":
                let dir = white ? 1 : -1
                if dr == dir && abs(df) == 1 { out.append(i) }
            case "n":
                if (abs(df) == 1 && abs(dr) == 2) || (abs(df) == 2 && abs(dr) == 1) { out.append(i) }
            case "k":
                if max(abs(df), abs(dr)) == 1 { out.append(i) }
            case "b":
                if abs(df) == abs(dr) && df != 0 && clear(from: i, to: t) { out.append(i) }
            case "r":
                if (df == 0) != (dr == 0) && clear(from: i, to: t) { out.append(i) }
            case "q":
                if ((abs(df) == abs(dr) && df != 0) || ((df == 0) != (dr == 0))) && clear(from: i, to: t) { out.append(i) }
            default: break
            }
        }
        return out
    }

    private func clear(from a: Int, to b: Int) -> Bool {
        let sf = (b % 8 - a % 8).signum(), sr = (b / 8 - a / 8).signum()
        var f = a % 8 + sf, r = a / 8 + sr
        while f != b % 8 || r != b / 8 {
            if cells[r * 8 + f] != nil { return false }
            f += sf; r += sr
        }
        return true
    }

    /// WintrChess's piece safety: is the piece on `i` in danger of being won?
    func isUnsafe(_ i: Int) -> Bool {
        guard let c = cells[i] else { return false }
        let white = Board64.isWhite(c)
        let v = Board64.value(c)
        let att = attackers(of: i, white: !white)
        if att.isEmpty { return false }
        let def = attackers(of: i, white: white)
        let attVals = att.compactMap { cells[$0] }.map(Board64.value)
        let cheapestAttacker = attVals.min() ?? 100
        // Attacked by something cheaper: unsafe.
        if cheapestAttacker < v { return true }
        // Defended by a pawn, or at least as many defenders as attackers: safe.
        if def.contains(where: { cells[$0]?.lowercased() == "p" }) { return false }
        if att.count <= def.count { return false }
        return true
    }

    /// Every unsafe piece of one colour, worth at least a minor piece.
    func unsafePieces(white: Bool) -> [Int] {
        cells.indices.filter { i in
            guard let c = cells[i], Board64.isWhite(c) == white, "nbrq".contains(c.lowercased()) else { return false }
            return isUnsafe(i)
        }
    }

    /// Material for `white` minus the other side, in pawns.
    func material(white: Bool) -> Int {
        cells.compactMap { $0 }.reduce(0) { acc, c in
            let v = c.lowercased() == "k" ? 0 : Board64.value(c)
            return acc + (Board64.isWhite(c) == white ? v : -v)
        }
    }

    func kingSquare(white: Bool) -> Int? { cells.firstIndex { $0 == (white ? "K" : "k") } }
}
