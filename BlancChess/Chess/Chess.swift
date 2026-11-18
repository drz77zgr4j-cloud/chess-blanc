import Foundation
import ChessKit

/// One move as the app passes it around: where it went, how it is written, and the position after it.
struct Ply: Hashable, Codable {
    let uci: String
    let san: String
    let fenAfter: String
    var from: String { String(uci.prefix(2)) }
    var to: String { String(uci.dropFirst(2).prefix(2)) }
}

enum PieceColor: String, Codable {
    case white = "w", black = "b"
    var opposite: PieceColor { self == .white ? .black : .white }
    var name: String { self == .white ? "White" : "Black" }
}

enum Chess {
    static let startFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

    static func position(_ fen: String) -> Position? { Position(fen: fen) }

    static func sideToMove(_ fen: String) -> PieceColor {
        fen.split(separator: " ").dropFirst().first == "b" ? .black : .white
    }

    /// Full-move number from the FEN.
    static func moveNumber(_ fen: String) -> Int {
        let parts = fen.split(separator: " ")
        return parts.count >= 6 ? Int(parts[5]) ?? 1 : 1
    }

    /// "4.d4" or "4…Nxe4" for the move played *from* `fenBefore`.
    static func numbered(_ san: String, fenBefore: String) -> String {
        let n = moveNumber(fenBefore)
        return sideToMove(fenBefore) == .white ? "\(n).\(san)" : "\(n)…\(san)"
    }

    static func square(_ s: String) -> Square { Square(s) }

    static func promotionKind(_ ch: Character?) -> Piece.Kind? {
        switch ch {
        case "q": .queen
        case "r": .rook
        case "b": .bishop
        case "n": .knight
        default: nil
        }
    }

    /// Plays a move given as UCI ("e2e4", "e7e8q"). Returns nil when illegal.
    static func play(_ uci: String, on fen: String) -> Ply? {
        guard uci.count >= 4 else { return nil }
        let from = String(uci.prefix(2))
        var to = String(uci.dropFirst(2).prefix(2))
        // Lichess writes castling as king-takes-rook (e1h1). Use the king's real target square.
        if let king = Position(fen: fen)?.piece(at: Square(from)), king.kind == .king {
            switch (from, to) {
            case ("e1", "h1"): to = "g1"
            case ("e1", "a1"): to = "c1"
            case ("e8", "h8"): to = "g8"
            case ("e8", "a8"): to = "c8"
            default: break
            }
        }
        let promo = uci.count > 4 ? promotionKind(uci.last) : nil
        return move(from: from, to: to, promotion: promo, on: fen)
    }

    static func move(from: String, to: String, promotion: Piece.Kind?, on fen: String) -> Ply? {
        guard let pos = Position(fen: fen) else { return nil }
        guard let piece = pos.piece(at: Square(from)), piece.color.rawValue == sideToMove(fen).rawValue else { return nil }
        var board = Board(position: pos)
        guard var mv = board.move(pieceAt: Square(from), to: Square(to)) else { return nil }
        if case let .promotion(pending) = board.state {
            mv = board.completePromotion(of: pending, to: promotion ?? .queen)
        }
        var uci = from + to
        if let p = mv.promotedPiece { uci += p.kind == .knight ? "n" : p.kind.rawValue.lowercased() }
        return Ply(uci: uci, san: mv.san, fenAfter: fixCounters(board.position.fen, before: fen))
    }

    /// The rules library doesn't always advance the move counter (e.g. after castling), so set it here:
    /// the full-move number goes up after every Black move.
    private static func fixCounters(_ after: String, before: String) -> String {
        var a = after.split(separator: " ").map(String.init)
        guard a.count >= 6 else { return after }
        let n = moveNumber(before)
        a[5] = String(sideToMove(before) == .black ? n + 1 : n)
        // It also keeps castling rights after a rook is captured; drop rights that no longer make sense.
        let joined = a.joined(separator: " ")
        return EngineService.safeFEN(joined) ?? joined
    }

    /// Replays UCI moves; stops at the first illegal one.
    static func replay(_ ucis: [String], from fen: String = startFEN) -> [Ply] {
        var out: [Ply] = []
        var current = fen
        for u in ucis {
            guard let p = play(u, on: current) else { break }
            out.append(p)
            current = p.fenAfter
        }
        return out
    }

    /// Converts SAN ("Nf3", "exd5", "O-O", "e8=Q+") to UCI in the given position.
    static func uci(fromSAN san: String, fen: String) -> String? {
        guard let pos = Position(fen: fen) else { return nil }
        let clean = san.replacingOccurrences(of: "!", with: "").replacingOccurrences(of: "?", with: "")
        guard let mv = Move(san: clean, position: pos) else { return nil }
        var u = mv.start.notation + mv.end.notation
        if let p = mv.promotedPiece { u += p.kind == .knight ? "n" : p.kind.rawValue.lowercased() }
        return u
    }

    static func legalTargets(from: String, fen: String) -> [String] {
        guard let pos = Position(fen: fen), let piece = pos.piece(at: Square(from)),
              piece.color.rawValue == sideToMove(fen).rawValue else { return [] }
        return Board(position: pos).legalMoves(forPieceAt: Square(from)).map(\.notation)
    }

    static func isPromotion(from: String, to: String, fen: String) -> Bool {
        guard let pos = Position(fen: fen), let piece = pos.piece(at: Square(from)), piece.kind == .pawn else { return false }
        return to.hasSuffix("8") || to.hasSuffix("1")
    }

    enum Outcome: Equatable { case active, check, checkmate(winner: PieceColor), draw(String) }

    static func outcome(_ fen: String) -> Outcome {
        guard let pos = Position(fen: fen) else { return .active }
        // A freshly built Board doesn't know its state until a move is made, so decide from the position.
        if !hasAnyLegalMove(fen) {
            return inCheck(fen) ? .checkmate(winner: sideToMove(fen).opposite) : .draw("stalemate")
        }
        switch Board(position: pos).state {
        case .draw(let reason): return .draw(reason.rawValue)
        default: return inCheck(fen) ? .check : .active
        }
    }

    static func hasAnyLegalMove(_ fen: String) -> Bool {
        guard let pos = Position(fen: fen) else { return false }
        let side = sideToMove(fen)
        let board = Board(position: pos)
        return pos.pieces.contains { $0.color.rawValue == side.rawValue && !board.legalMoves(forPieceAt: $0.square).isEmpty }
    }

    /// Every legal move in UCI (promotions without the piece letter).
    static func legalUCIs(_ fen: String) -> [String] {
        guard let pos = Position(fen: fen) else { return [] }
        let side = sideToMove(fen)
        let board = Board(position: pos)
        return pos.pieces.filter { $0.color.rawValue == side.rawValue }.flatMap { p in
            board.legalMoves(forPieceAt: p.square).map { p.square.notation + $0.notation }
        }
    }

    static func legalMoveCount(_ fen: String) -> Int {
        guard let pos = Position(fen: fen) else { return 0 }
        let side = sideToMove(fen)
        let board = Board(position: pos)
        return pos.pieces.filter { $0.color.rawValue == side.rawValue }
            .reduce(0) { $0 + board.legalMoves(forPieceAt: $1.square).count }
    }

    /// Is the side to move in check?
    static func inCheck(_ fen: String) -> Bool {
        let b = Board64(fen: fen)
        guard let k = b.kingSquare(white: b.whiteToMove) else { return false }
        return !b.attackers(of: k, white: !b.whiteToMove).isEmpty
    }

    /// Material of `color` minus the other side, in pawns.
    static func material(_ fen: String, for color: PieceColor) -> Int {
        let board = fen.split(separator: " ").first ?? ""
        var score = 0
        for ch in board {
            let v: Int
            switch ch.lowercased() {
            case "p": v = 1
            case "n", "b": v = 3
            case "r": v = 5
            case "q": v = 9
            default: v = 0
            }
            let isWhite = ch.isUppercase
            score += (isWhite == (color == .white)) ? v : -v
        }
        return score
    }

    /// Piece placement only, for comparing positions regardless of move counters.
    static func placementKey(_ fen: String) -> String {
        fen.split(separator: " ").prefix(4).joined(separator: " ")
    }

    /// Pieces on the board as (square, colour, kind letter "K","Q","R","B","N","P").
    static func pieces(_ fen: String) -> [(square: String, color: PieceColor, kind: String)] {
        var out: [(String, PieceColor, String)] = []
        let files = Array("abcdefgh")
        let rows = (fen.split(separator: " ").first ?? "").split(separator: "/")
        for (r, row) in rows.enumerated() {
            var file = 0
            for ch in row {
                if let n = ch.wholeNumberValue { file += n; continue }
                guard file < 8, r < 8 else { break }
                let sq = "\(files[file])\(8 - r)"
                out.append((sq, ch.isUppercase ? .white : .black, ch.uppercased()))
                file += 1
            }
        }
        return out
    }

    /// Builds a FEN from a piece map; castling rights guessed from king/rook home squares.
    static func fen(from pieces: [String: (PieceColor, String)], sideToMove: PieceColor) -> String {
        var rows: [String] = []
        for rank in stride(from: 8, through: 1, by: -1) {
            var row = "", empty = 0
            for f in "abcdefgh" {
                if let p = pieces["\(f)\(rank)"] {
                    if empty > 0 { row += "\(empty)"; empty = 0 }
                    row += p.0 == .white ? p.1.uppercased() : p.1.lowercased()
                } else { empty += 1 }
            }
            if empty > 0 { row += "\(empty)" }
            rows.append(row)
        }
        var castle = ""
        func has(_ sq: String, _ c: PieceColor, _ k: String) -> Bool { pieces[sq].map { $0.0 == c && $0.1 == k } ?? false }
        if has("e1", .white, "K") { if has("h1", .white, "R") { castle += "K" }; if has("a1", .white, "R") { castle += "Q" } }
        if has("e8", .black, "K") { if has("h8", .black, "R") { castle += "k" }; if has("a8", .black, "R") { castle += "q" } }
        return rows.joined(separator: "/") + " \(sideToMove.rawValue) \(castle.isEmpty ? "-" : castle) - 0 1"
    }

    /// Converts an engine PV (UCI) into SAN, as far as it stays legal.
    static func sanLine(_ pv: [String], from fen: String, limit: Int = 12) -> [String] {
        var current = fen
        var out: [String] = []
        for u in pv.prefix(limit) {
            guard let p = play(u, on: current) else { break }
            out.append(numberedIfNeeded(p.san, fenBefore: current, isFirst: out.isEmpty))
            current = p.fenAfter
        }
        return out
    }

    private static func numberedIfNeeded(_ san: String, fenBefore: String, isFirst: Bool) -> String {
        if sideToMove(fenBefore) == .white { return "\(moveNumber(fenBefore)).\(san)" }
        return isFirst ? "\(moveNumber(fenBefore))…\(san)" : san
    }
}
