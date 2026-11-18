import SwiftUI

/// Plays a line of moves out on a board, one move at a time with sounds and arrows,
/// so you can see why the best move is best. Shared by puzzles, challenges and endgames.
@MainActor
final class LinePlayer: ObservableObject {
    @Published private(set) var plies: [Ply] = []
    @Published private(set) var index = 0
    @Published private(set) var playing = false
    private(set) var start = ""
    private(set) var colour: Color = BC.mint
    private weak var board: BoardState?
    private var task: Task<Void, Never>?

    var isActive: Bool { !plies.isEmpty }

    func play(_ pv: [String], from fen: String, on board: BoardState, colour: Color = BC.mint, limit: Int = 10) {
        task?.cancel()
        let line = Chess.replay(Array(pv.prefix(limit)), from: fen)
        guard !line.isEmpty else { return }
        self.board = board
        self.colour = colour
        start = fen
        plies = line
        playing = true
        step(to: 0)
        task = Task { @MainActor [weak self] in
            for k in 1...line.count {
                try? await Task.sleep(nanoseconds: 850_000_000)
                guard let self, !Task.isCancelled else { return }
                self.step(to: k)
            }
            self?.playing = false
        }
    }

    func replay() {
        guard let board else { return }
        play(plies.map(\.uci), from: start, on: board, colour: colour)
    }

    func step(to k: Int) {
        guard let board, k >= 0, k <= plies.count else { return }
        index = k
        let fen = k == 0 ? start : plies[k - 1].fenAfter
        let last = k == 0 ? nil : MovePair(from: plies[k - 1].from, to: plies[k - 1].to)
        board.badge = nil
        board.tints = [:]
        board.set(fen: fen, lastMove: last)
        if k > 0 { Feedback.move(san: plies[k - 1].san) }
        board.arrows = k < plies.count
            ? [BoardArrow(from: plies[k].from, to: plies[k].to, colour: colour, opacity: 0.7)] : []
    }

    func clear() {
        task?.cancel()
        playing = false
        plies = []
        index = 0
    }

    func numbered(_ k: Int) -> String {
        Chess.numbered(plies[k].san, fenBefore: k == 0 ? start : plies[k - 1].fenAfter)
    }
}

/// The moves of a playing line as tappable chips that follow along.
struct LineStrip: View {
    @ObservedObject var player: LinePlayer

    var body: some View {
        HStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 5) {
                        ForEach(0..<player.plies.count, id: \.self) { k in
                            let on = player.index == k + 1
                            Button { player.step(to: k + 1) } label: {
                                Text(player.numbered(k))
                                    .font(.system(size: 14, weight: on ? .bold : .semibold))
                                    .foregroundStyle(on ? .black : (k < player.index ? BC.ink : BC.mute))
                                    .padding(.horizontal, 9).frame(height: 30)
                                    .background(on ? player.colour : BC.raised, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .id(k)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .onChange(of: player.index) { _, i in
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(max(0, i - 1), anchor: .center) }
                }
            }
            Button { player.replay() } label: {
                Image(systemName: "arrow.counterclockwise").font(.system(size: 13, weight: .bold)).foregroundStyle(BC.ink)
                    .frame(width: 30, height: 30).background(BC.raised, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Replay the line")
        }
    }
}
