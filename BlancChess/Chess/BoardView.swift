import SwiftUI
import ChessKit

/// The interactive board: drag or tap to move, legal-move dots, last move, tints, arrows, badges.
struct BoardView: View {
    @ObservedObject var state: BoardState
    /// The board colours and piece set when this was made, so a change redraws it.
    var look = BoardLook.current

    @State private var dragID: Int? = nil
    @State private var dragStart: String? = nil
    @State private var dragPoint: CGPoint = .zero
    @State private var selectionBeforeGesture: String? = nil

    /// Side length in points, from the space the screen gives it (see BoardLayout).
    var size: CGFloat

    var body: some View {
        let size = self.size
        let q = size / 8
        return Group {
            ZStack(alignment: .topLeading) {
                squares(q: q)
                ForEach(state.targets, id: \.self) { sq in
                    targetMark(sq, q: q)
                }
                ForEach(state.pieces) { piece in
                    let dragging = piece.id == dragID
                    Image(piece.imageName)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: q, height: q)
                        .scaleEffect(dragging ? 1.18 : 1)
                        .position(dragging ? dragPoint : center(piece.square, q: q))
                        .zIndex(dragging ? 10 : 1)
                        .allowsHitTesting(false)
                }
                arrows(q: q).allowsHitTesting(false).zIndex(20)
                if let b = state.badge {
                    ClassBadge(cls: b.cls, size: max(18, q * 0.44))
                        .position(badgePoint(b.square, q: q))
                        .zIndex(30)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .gesture(dragGesture(q: q))
            .overlay {
                if let p = state.pendingPromotion { promotionPicker(p, q: q) }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var s = "Chess board. \(state.sideToMove.name) to move."
        if let lm = state.lastMove { s += " Last move \(lm.from) to \(lm.to)." }
        return s
    }

    // MARK: Geometry

    private func center(_ square: String, q: CGFloat) -> CGPoint {
        let f = CGFloat(Int(square.unicodeScalars.first!.value) - 97)
        let r = CGFloat(Int(String(square.last!)) ?? 1)
        let col = state.flipped ? 7 - f : f
        let row = state.flipped ? r - 1 : 8 - r
        return CGPoint(x: (col + 0.5) * q, y: (row + 0.5) * q)
    }

    private func square(at p: CGPoint, q: CGFloat) -> String? {
        guard p.x >= 0, p.y >= 0, p.x < q * 8, p.y < q * 8 else { return nil }
        var col = Int(p.x / q), row = Int(p.y / q)
        if state.flipped { col = 7 - col; row = 7 - row }
        let files = Array("abcdefgh")
        return "\(files[col])\(8 - row)"
    }

    private func badgePoint(_ square: String, q: CGFloat) -> CGPoint {
        let c = center(square, q: q)
        let x = min(q * 8 - q * 0.22, c.x + q * 0.42)
        let y = max(q * 0.22, c.y - q * 0.42)
        return CGPoint(x: x, y: y)
    }

    // MARK: Layers

    private func squares(q: CGFloat) -> some View {
        Canvas { ctx, _ in
            let files = Array("abcdefgh")
            for row in 0..<8 {
                for col in 0..<8 {
                    let f = state.flipped ? 7 - col : col
                    let r = state.flipped ? row + 1 : 8 - row
                    let sq = "\(files[f])\(r)"
                    let light = (f + r) % 2 == 0
                    let rect = CGRect(x: CGFloat(col) * q, y: CGFloat(row) * q, width: q, height: q)
                    ctx.fill(Path(rect), with: .color(light ? BC.lightSquare : BC.darkSquare))
                    if let lm = state.lastMove, lm.from == sq || lm.to == sq {
                        ctx.fill(Path(rect), with: .color(BC.lastMove))
                    }
                    if state.selected == sq {
                        ctx.fill(Path(rect), with: .color(BC.lastMove))
                    }
                    switch state.tints[sq] {
                    case .right?: ctx.fill(Path(rect), with: .color(BC.mint.opacity(0.75)))
                    case .wrong?: ctx.fill(Path(rect), with: .color(BC.coral.opacity(0.78)))
                    case .hint?:
                        let inset = max(2, q * 0.05)
                        ctx.stroke(Path(rect.insetBy(dx: inset, dy: inset)), with: .color(BC.blue), lineWidth: max(3, q * 0.08))
                    case nil: break
                    }
                    if state.showCoordinates {
                        let ink = light ? BC.darkSquare : BC.lightSquare
                        let fs = max(9, q * 0.22)
                        if col == 0 {
                            ctx.draw(Text("\(r)").font(.system(size: fs, weight: .bold)).foregroundColor(ink),
                                     at: CGPoint(x: rect.minX + 3, y: rect.minY + 2), anchor: .topLeading)
                        }
                        if row == 7 {
                            ctx.draw(Text(String(files[f])).font(.system(size: fs, weight: .bold)).foregroundColor(ink),
                                     at: CGPoint(x: rect.maxX - 3, y: rect.maxY - 1), anchor: .bottomTrailing)
                        }
                    }
                }
            }
        }
        .frame(width: q * 8, height: q * 8)
    }

    private func targetMark(_ sq: String, q: CGFloat) -> some View {
        let occupied = state.pieces.contains { $0.square == sq }
        return Group {
            if occupied {
                Circle().stroke(Color.black.opacity(0.2), lineWidth: q * 0.09).frame(width: q * 0.9, height: q * 0.9)
            } else {
                Circle().fill(Color.black.opacity(0.18)).frame(width: q * 0.3, height: q * 0.3)
            }
        }
        .position(center(sq, q: q))
        .allowsHitTesting(false)
    }

    private func arrows(q: CGFloat) -> some View {
        Canvas { ctx, _ in
            for a in state.arrows {
                let p1 = center(a.from, q: q), p2 = center(a.to, q: q)
                let dx = p2.x - p1.x, dy = p2.y - p1.y
                let len = sqrt(dx * dx + dy * dy)
                guard len > 1 else { continue }
                let ux = dx / len, uy = dy / len, nx = -uy, ny = ux
                let start = CGPoint(x: p1.x + ux * q * 0.22, y: p1.y + uy * q * 0.22)
                let head = q * 0.42, w = q * 0.19 / 2, hw = q * 0.48 / 2
                let base = CGPoint(x: p2.x - ux * head, y: p2.y - uy * head)
                var path = Path()
                path.move(to: CGPoint(x: start.x + nx * w, y: start.y + ny * w))
                path.addLine(to: CGPoint(x: base.x + nx * w, y: base.y + ny * w))
                path.addLine(to: CGPoint(x: base.x + nx * hw, y: base.y + ny * hw))
                path.addLine(to: p2)
                path.addLine(to: CGPoint(x: base.x - nx * hw, y: base.y - ny * hw))
                path.addLine(to: CGPoint(x: base.x - nx * w, y: base.y - ny * w))
                path.addLine(to: CGPoint(x: start.x - nx * w, y: start.y - ny * w))
                path.closeSubpath()
                ctx.fill(path, with: .color(a.colour.opacity(a.opacity)))
            }
        }
        .frame(width: q * 8, height: q * 8)
    }

    // MARK: Gesture

    private func dragGesture(q: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if dragStart == nil {
                    guard let sq = square(at: value.startLocation, q: q) else { return }
                    dragStart = sq
                    selectionBeforeGesture = state.selected
                    if let p = state.pieces.first(where: { $0.square == sq }), state.canMove(p.color) {
                        state.select(sq)
                        dragID = p.id
                    }
                }
                if dragID != nil {
                    let moved = hypot(value.translation.width, value.translation.height)
                    if moved > 3 {
                        dragPoint = CGPoint(x: min(max(value.location.x, 0), q * 8), y: min(max(value.location.y, 0), q * 8))
                    } else if let start = dragStart {
                        dragPoint = center(start, q: q)
                    }
                }
            }
            .onEnded { value in
                defer {
                    withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.2)) { dragID = nil }
                    dragStart = nil
                    selectionBeforeGesture = nil
                }
                guard let start = dragStart else { return }
                let end = square(at: value.location, q: q)
                let moved = hypot(value.translation.width, value.translation.height) > 8
                if moved, dragID != nil, let end, end != start {
                    state.attempt(from: start, to: end, byDrag: true)
                    return
                }
                // A tap
                if let prev = selectionBeforeGesture, prev != start,
                   Chess.legalTargets(from: prev, fen: state.fen).contains(start) {
                    state.attempt(from: prev, to: start, byDrag: false)
                    return
                }
                if dragID == nil {
                    state.select(nil)
                } else if selectionBeforeGesture == start {
                    state.select(nil)
                }
            }
    }

    // MARK: Promotion

    private func promotionPicker(_ p: MovePair, q: CGFloat) -> some View {
        let color = state.sideToMove
        return ZStack {
            Color.black.opacity(0.55)
            VStack(spacing: 12) {
                Text("Promote to").font(.bcBodyStrong).foregroundStyle(BC.ink)
                HStack(spacing: 10) {
                    ForEach([("Q", Piece.Kind.queen), ("R", .rook), ("B", .bishop), ("N", .knight)], id: \.0) { item in
                        Button {
                            state.completePromotion(item.1)
                        } label: {
                            Image(PieceSet.image("\(color.rawValue)\(item.0)"))
                                .resizable()
                                .frame(width: q * 1.1, height: q * 1.1)
                                .background(BC.raised, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(PressStyle())
                    }
                }
                Button("Cancel") { state.pendingPromotion = nil }
                    .font(.bcCaption).foregroundStyle(BC.mute)
            }
            .padding(18)
            .background(BC.card, in: RoundedRectangle(cornerRadius: BC.rCard))
        }
    }
}
