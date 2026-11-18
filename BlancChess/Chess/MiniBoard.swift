import SwiftUI
import UIKit

/// A small static board for lists and previews. Drawn in one Canvas so long lists stay smooth, and only
/// redrawn when what it shows changes (not every time the list around it updates).
struct MiniBoard: View {
    let fen: String
    var size: CGFloat = 64
    var flipped: Bool = false
    var highlight: [String] = []
    var arrow: MovePair? = nil
    var arrowColour: Color = BC.arrow
    var radius: CGFloat = 9
    /// The board colours and piece set when this was made, so a change redraws it.
    var look = BoardLook.current

    static let symbolIDs = ["wK", "wQ", "wR", "wB", "wN", "wP", "bK", "bQ", "bR", "bB", "bN", "bP"]

    var body: some View {
        MiniBoardCanvas(fen: fen, size: size, flipped: flipped, highlight: highlight, arrow: arrow,
                        arrowColour: arrowColour, radius: radius, look: look)
            .equatable()
    }
}

/// The drawing itself: equal inputs, no redraw.
private struct MiniBoardCanvas: View, Equatable {
    let fen: String
    let size: CGFloat
    let flipped: Bool
    let highlight: [String]
    let arrow: MovePair?
    let arrowColour: Color
    let radius: CGFloat
    let look: String

    var body: some View {
        Canvas { ctx, _ in
            let q = size / 8
            let files = Array("abcdefgh")
            func rect(_ sq: String) -> CGRect {
                let f = CGFloat(Int(sq.unicodeScalars.first!.value) - 97)
                let r = CGFloat(Int(String(sq.last!)) ?? 1)
                let col = flipped ? 7 - f : f
                let row = flipped ? r - 1 : 8 - r
                return CGRect(x: col * q, y: row * q, width: q, height: q)
            }
            for f in 0..<8 {
                for r in 1...8 {
                    let sq = "\(files[f])\(r)"
                    let light = (f + r) % 2 == 0
                    ctx.fill(Path(rect(sq)), with: .color(light ? BC.lightSquare : BC.darkSquare))
                    if highlight.contains(sq) { ctx.fill(Path(rect(sq)), with: .color(BC.lastMove)) }
                }
            }
            for p in Chess.pieces(fen) {
                if let img = ctx.resolveSymbol(id: "\(p.color.rawValue)\(p.kind)") {
                    ctx.draw(img, in: rect(p.square))
                }
            }
            if let arrow {
                let a = rect(arrow.from), b = rect(arrow.to)
                let p0 = CGPoint(x: a.midX, y: a.midY), p1 = CGPoint(x: b.midX, y: b.midY)
                let dx = p1.x - p0.x, dy = p1.y - p0.y
                let len = max(1, (dx * dx + dy * dy).squareRoot())
                let ux = dx / len, uy = dy / len
                let head = q * 0.5, half = q * 0.3
                let base = CGPoint(x: p1.x - ux * head, y: p1.y - uy * head)
                var path = Path()
                path.move(to: p0)
                path.addLine(to: base)
                ctx.stroke(path, with: .color(arrowColour.opacity(0.85)), style: StrokeStyle(lineWidth: q * 0.2, lineCap: .round))
                var tip = Path()
                tip.move(to: p1)
                tip.addLine(to: CGPoint(x: base.x - uy * half, y: base.y + ux * half))
                tip.addLine(to: CGPoint(x: base.x + uy * half, y: base.y - ux * half))
                tip.closeSubpath()
                ctx.fill(tip, with: .color(arrowColour.opacity(0.85)))
            }
        } symbols: {
            ForEach(MiniBoard.symbolIDs, id: \.self) { id in
                Image(PieceSet.image(id)).resizable().frame(width: size / 8, height: size / 8).tag(id)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .accessibilityHidden(true)
    }
}
