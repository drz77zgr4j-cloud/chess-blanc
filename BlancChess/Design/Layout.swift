import SwiftUI

// Layout for every window: iPhone SE to the largest iPad, Split View and Stage Manager included.
// Sizes come from the space a view is given (GeometryReader), never from UIScreen, which is wrong
// in a window that doesn't fill the screen.

extension BC {
    /// The widest a column of cards and rows gets: on an iPad, list screens sit in a centred column this wide.
    static let readable: CGFloat = 680
    /// The widest a board screen's single column gets (board, cards and toolbar).
    static let boardColumn: CGFloat = 880
    /// The widest the dock gets.
    static let dockWidth: CGFloat = 440
}

extension View {
    /// Centres the content in a column at most `width` wide. On a phone the column is the whole width.
    func readableColumn(_ width: CGFloat = BC.readable) -> some View {
        frame(maxWidth: width).frame(maxWidth: .infinity)
    }
}

/// The body of a board screen, under its nav bar.
///
/// Phones and tall windows: one column. The board is as big as the room left after `reserve` points
/// for everything else (`top` above it, `panel` below), and the column is at most `BC.boardColumn` wide.
/// Wide windows (an iPad on its side): the board on the left as tall as the window allows, and `top`
/// then `panel` in a column on the right.
struct BoardLayout<Top: View, Board: View, Panel: View>: View {
    /// Height everything but the board needs in the single column.
    private let reserve: CGFloat
    private let minBoard: CGFloat
    /// Above the board in the single column, at the top of the side column when wide. Gets the width it spans.
    private let top: (CGFloat) -> Top
    /// The board at a side length.
    private let board: (CGFloat) -> Board
    /// Below the board in the single column, under `top` in the side column when wide.
    private let panel: Panel

    init(reserve: CGFloat, minBoard: CGFloat = 240, @ViewBuilder top: @escaping (CGFloat) -> Top,
         @ViewBuilder board: @escaping (CGFloat) -> Board, @ViewBuilder panel: () -> Panel) {
        self.reserve = reserve
        self.minBoard = minBoard
        self.top = top
        self.board = board
        self.panel = panel()
    }

    static func isWide(_ size: CGSize) -> Bool { size.width >= 700 && size.width > size.height * 1.15 }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            if Self.isWide(geo.size) {
                let sideW = min(460, max(340, w * 0.36))
                let size = max(minBoard, min(h - 16, w - sideW - 2 * BC.side - 8))
                HStack(alignment: .top, spacing: 8) {
                    board(size)
                        .frame(width: size, height: size)
                    VStack(spacing: 0) {
                        top(sideW)
                        panel
                    }
                    .frame(width: sideW, height: max(size, min(h, 560)))
                }
                .frame(width: w, height: h)
            } else {
                let col = min(w, BC.boardColumn)
                let size = min(col, max(minBoard, h - reserve))
                VStack(spacing: 0) {
                    top(size)
                    board(size)
                        .frame(width: col, height: size)
                    panel
                }
                .frame(width: col, height: h)
                .frame(width: w)
            }
        }
    }
}

extension BoardLayout where Top == EmptyView {
    init(reserve: CGFloat, minBoard: CGFloat = 240, @ViewBuilder board: @escaping (CGFloat) -> Board, @ViewBuilder panel: () -> Panel) {
        self.init(reserve: reserve, minBoard: minBoard, top: { _ in EmptyView() }, board: board, panel: panel)
    }
}
