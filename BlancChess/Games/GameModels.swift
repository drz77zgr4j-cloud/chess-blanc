import Foundation

enum GameResult: String, Codable { case win, loss, draw
    var letter: String { switch self { case .win: "W"; case .loss: "L"; case .draw: "D" } }
}

struct GameReview: Codable, Hashable {
    var classes: [MoveClass]      // one per ply
    var evals: [Double]           // White-side centipawns after each ply (mate = ±1500)
    var best: [String]            // engine best move in the position before each ply
    var bestLines: [[String]]     // a few moves of the best line before each ply
    var accuracyWhite: Double
    var accuracyBlack: Double
    var depth: Int
    var reviewedAt: Date
    /// What each slip cost (hung a piece, allowed mate…), for coaching and insights.
    var themes: [Eval.Theme?]? = nil
    /// The square a theme is about (the hanging piece, say).
    var squares: [String?]? = nil
    /// 2 = the current classification rules. Older reviews get redone.
    var version: Int? = nil

    static let currentVersion = 2
}

struct GameRecord: Codable, Identifiable, Hashable {
    let id: String
    let url: String
    let endTime: Date
    let timeClass: String
    let rated: Bool
    let white: String
    let whiteRating: Int
    let black: String
    let blackRating: Int
    let userColor: PieceColor
    let result: GameResult
    let resultDetail: String
    let opening: String
    let family: String
    let startFEN: String
    let ucis: [String]
    let sans: [String]
    var chessComAccuracy: Double?
    var review: GameReview?
    /// Seconds left on the mover's clock after each ply, from the PGN.
    var clocks: [Double]? = nil

    var opponent: String { userColor == .white ? black : white }
    var opponentRating: Int { userColor == .white ? blackRating : whiteRating }
    var userRating: Int { userColor == .white ? whiteRating : blackRating }
    var userAccuracy: Double? {
        if let r = review { return userColor == .white ? r.accuracyWhite : r.accuracyBlack }
        return nil      // only our own review's figure: chess.com's number isn't ours to show
    }

    /// FEN before each ply, plus the final position.
    var fens: [String] {
        var out = [startFEN]
        var cur = startFEN
        for u in ucis {
            guard let p = Chess.play(u, on: cur) else { break }
            out.append(p.fenAfter)
            cur = p.fenAfter
        }
        return out
    }

    func userClasses() -> [MoveClass] {
        guard let r = review else { return [] }
        return r.classes.enumerated().compactMap { i, c in moverAt(i) == userColor ? c : nil }
    }

    func moverAt(_ ply: Int) -> PieceColor {
        let first = Chess.sideToMove(startFEN)
        return ply % 2 == 0 ? first : first.opposite
    }

    func count(_ cls: MoveClass) -> Int {
        guard let r = review else { return 0 }
        return r.classes.enumerated().filter { moverAt($0.offset) == userColor && $0.element == cls }.count
    }

    static func == (a: GameRecord, b: GameRecord) -> Bool { a.id == b.id && a.review == b.review }
    func hash(into h: inout Hasher) { h.combine(id) }
}

// MARK: - PGN

enum PGN {
    static func headers(_ pgn: String) -> [String: String] {
        var out: [String: String] = [:]
        let re = try! NSRegularExpression(pattern: #"\[(\w+)\s+"(.*?)"\]"#)
        let ns = pgn as NSString
        for m in re.matches(in: pgn, range: NSRange(location: 0, length: ns.length)) {
            out[ns.substring(with: m.range(at: 1))] = ns.substring(with: m.range(at: 2))
        }
        return out
    }

    /// SAN tokens of the main line.
    static func sanMoves(_ pgn: String) -> [String] {
        var text = pgn.components(separatedBy: "\n").filter { !$0.hasPrefix("[") }.joined(separator: " ")
        text = text.replacingOccurrences(of: #"\{[^}]*\}"#, with: " ", options: .regularExpression)
        // drop variations (no nesting in chess.com PGNs, but loop just in case)
        while text.contains("(") {
            let before = text
            text = text.replacingOccurrences(of: #"\([^()]*\)"#, with: " ", options: .regularExpression)
            if text == before { break }
        }
        text = text.replacingOccurrences(of: #"\$\d+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\d+\.(\.\.)?"#, with: " ", options: .regularExpression)
        return text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map(String.init)
            .filter { !["1-0", "0-1", "1/2-1/2", "*"].contains($0) && !$0.isEmpty }
    }

    /// Seconds on the clock after each move, from chess.com's [%clk h:mm:ss.s] comments.
    static func clocks(_ pgn: String) -> [Double] {
        let re = try! NSRegularExpression(pattern: #"\[%clk (\d+):(\d+):(\d+(?:\.\d+)?)\]"#)
        let ns = pgn as NSString
        return re.matches(in: pgn, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard let h = Double(ns.substring(with: m.range(at: 1))), let mi = Double(ns.substring(with: m.range(at: 2))),
                  let s = Double(ns.substring(with: m.range(at: 3))) else { return nil }
            return h * 3600 + mi * 60 + s
        }
    }

    /// "https://www.chess.com/openings/Caro-Kann-Defense-Advance-Variation-3...Bf5" → "Caro-Kann Defense Advance Variation"
    static func openingName(ecoURL: String?) -> String {
        guard let ecoURL, let last = ecoURL.split(separator: "/").last else { return "Unknown opening" }
        var s = String(last)
        if let r = s.range(of: #"-\d+\..*$"#, options: .regularExpression) { s.removeSubrange(r) }
        s = s.replacingOccurrences(of: "-", with: " ")
        let fixes = ["Caro Kann": "Caro-Kann", "Kings ": "King's ", "Queens ": "Queen's ", "Bishops ": "Bishop's ",
                     "Ruy Lopez": "Ruy López", "Nimzo Larsen": "Nimzo-Larsen", "Nimzo Indian": "Nimzo-Indian"]
        for (a, b) in fixes { s = s.replacingOccurrences(of: a, with: b) }
        return s.isEmpty ? "Unknown opening" : s
    }

    static func family(of name: String) -> String {
        let words = name.split(separator: " ").map(String.init)
        let enders: Set<String> = ["Opening", "Defense", "Game", "Gambit", "Attack", "System", "Countergambit"]
        for (i, w) in words.enumerated() where enders.contains(w) {
            return words[...i].joined(separator: " ")
        }
        return words.prefix(2).joined(separator: " ")
    }
}
