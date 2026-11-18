import SwiftUI
import ChessKit

struct BoardPiece: Identifiable, Equatable {
    let id: Int
    var color: PieceColor
    var kind: String      // "K","Q","R","B","N","P"
    var square: String
    var imageName: String { PieceSet.image("\(color.rawValue)\(kind)") }
}

struct BoardArrow: Identifiable, Equatable {
    let from: String
    let to: String
    var colour: Color = BC.arrow
    var opacity: Double = 0.85
    var id: String { from + to + "\(opacity)" }
}

enum SquareTint: Equatable { case right, wrong, hint }

struct MovePair: Equatable { let from: String; let to: String }

struct BoardBadge: Equatable { let square: String; let cls: MoveClass }

/// Everything the board shows. Screens own one and drive it; the board reports attempted moves.
@MainActor
final class BoardState: ObservableObject {
    @Published private(set) var fen: String
    @Published private(set) var pieces: [BoardPiece] = []
    @Published var flipped = false
    @Published var lastMove: MovePair?
    @Published var tints: [String: SquareTint] = [:]
    @Published var arrows: [BoardArrow] = []
    @Published var badge: BoardBadge?
    @Published var selected: String?
    @Published var targets: [String] = []
    @Published var pendingPromotion: MovePair?
    @Published var showCoordinates = true

    /// Which side the user may move. nil = look only.
    var userColor: PieceColor? = nil
    /// Analysis board: move either side.
    var bothSides = false
    /// Called when the user tries a legal move. The screen decides what happens.
    var onMove: ((String, String, Piece.Kind?) -> Void)?

    fileprivate var dragDrop = false
    private var nextID = 1

    init(fen: String = Chess.startFEN) {
        self.fen = fen
        self.pieces = []
        rebuild(fen: fen, moved: nil)
    }

    var sideToMove: PieceColor { Chess.sideToMove(fen) }

    func canMove(_ color: PieceColor) -> Bool {
        guard color == sideToMove else { return false }
        return bothSides || userColor == color
    }

    /// Show a new position. Pieces keep their identity so they slide.
    func set(fen newFEN: String, lastMove move: MovePair? = nil, animated: Bool = true) {
        let animate = animated && !dragDrop
        dragDrop = false
        let apply = {
            self.rebuild(fen: newFEN, moved: move)
            self.fen = newFEN
            self.lastMove = move
            self.selected = nil
            self.targets = []
        }
        if animate {
            withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.24)) { apply() }
        } else {
            apply()
        }
    }

    func clearMarks() {
        tints = [:]
        arrows = []
        badge = nil
    }

    func select(_ square: String?) {
        guard let square, let p = pieces.first(where: { $0.square == square }), canMove(p.color) else {
            selected = nil; targets = []; return
        }
        selected = square
        targets = Chess.legalTargets(from: square, fen: fen)
    }

    func attempt(from: String, to: String, byDrag: Bool) {
        guard Chess.legalTargets(from: from, fen: fen).contains(to) else { return }
        selected = nil
        targets = []
        if Chess.isPromotion(from: from, to: to, fen: fen) {
            pendingPromotion = MovePair(from: from, to: to)
            return
        }
        dragDrop = byDrag
        onMove?(from, to, nil)
        dragDrop = false
    }

    func completePromotion(_ kind: Piece.Kind) {
        guard let p = pendingPromotion else { return }
        pendingPromotion = nil
        onMove?(p.from, p.to, kind)
    }

    private func rebuild(fen newFEN: String, moved: MovePair?) {
        let target = Chess.pieces(newFEN)
        var old = pieces
        var result: [BoardPiece] = []
        var unmatched: [(square: String, color: PieceColor, kind: String)] = []
        // 1. unchanged squares keep their piece
        for t in target {
            if let i = old.firstIndex(where: { $0.square == t.square && $0.color == t.color && $0.kind == t.kind }) {
                result.append(old.remove(at: i))
            } else {
                unmatched.append(t)
            }
        }
        // 2. moved pieces: prefer the piece from the move's start square, then same kind nearest
        for t in unmatched {
            var idx: Int? = nil
            if let m = moved, t.square == m.to, let i = old.firstIndex(where: { $0.square == m.from && $0.color == t.color }) {
                idx = i
            }
            if idx == nil {
                idx = old.enumerated()
                    .filter { $0.element.color == t.color && $0.element.kind == t.kind }
                    .min(by: { distance($0.element.square, t.square) < distance($1.element.square, t.square) })?.offset
            }
            if let i = idx {
                var p = old.remove(at: i)
                p.square = t.square
                p.kind = t.kind
                result.append(p)
            } else {
                result.append(BoardPiece(id: nextID, color: t.color, kind: t.kind, square: t.square))
                nextID += 1
            }
        }
        pieces = result.sorted { $0.id < $1.id }
    }

    private func distance(_ a: String, _ b: String) -> Int {
        let fa = Int(a.unicodeScalars.first!.value) - 97, ra = Int(String(a.last!)) ?? 0
        let fb = Int(b.unicodeScalars.first!.value) - 97, rb = Int(String(b.last!)) ?? 0
        return abs(fa - fb) + abs(ra - rb)
    }
}
