import SwiftUI
import ChessKit

/// The six endgames every club player should be able to do against full-strength Stockfish.
struct EndgameDrill: Identifiable {
    enum Goal { case mate, promote, hold(moves: Int) }
    let id: String
    let title: String
    let detail: String
    let fen: String
    let goal: Goal
    let moveLimit: Int

    var you: PieceColor { Chess.sideToMove(fen) }

    var goalText: String {
        switch goal {
        case .mate: "Checkmate within \(moveLimit) moves."
        case .promote: "Promote your pawn within \(moveLimit) moves."
        case .hold(let n): "Hold for \(n) moves without the pawn queening."
        }
    }

    var kindTag: (String, Color) {
        switch goal {
        case .mate: ("Mate", BC.mint)
        case .promote: ("Win", BC.mint)
        case .hold: ("Draw", BC.mute)
        }
    }

    static let all: [EndgameDrill] = [
        .init(id: "kq", title: "King and queen mate", detail: "Push the king to the edge, then mate. Watch out for stalemate.",
              fen: "8/8/8/4k3/8/8/8/3QK3 w - - 0 1", goal: .mate, moveLimit: 15),
        .init(id: "kr", title: "King and rook mate", detail: "Use the rook as a fence and your king for opposition.",
              fen: "8/8/8/4k3/8/8/8/R3K3 w - - 0 1", goal: .mate, moveLimit: 25),
        .init(id: "kpw", title: "King and pawn: win", detail: "Your king is in front of the pawn. Take the opposition and promote.",
              fen: "4k3/8/4K3/4P3/8/8/8/8 w - - 0 1", goal: .promote, moveLimit: 15),
        .init(id: "kpd", title: "King and pawn: draw", detail: "Stay in front of the pawn and keep the opposition.",
              fen: "4k3/8/8/4P3/4K3/8/8/8 b - - 0 1", goal: .hold(moves: 20), moveLimit: 20),
        .init(id: "lucena", title: "Lucena: build a bridge", detail: "Get your king out, then shield it from checks with your rook.",
              fen: "1K1k4/1P6/8/8/8/8/r7/2R5 w - - 0 1", goal: .promote, moveLimit: 20),
        .init(id: "philidor", title: "Philidor: hold the draw", detail: "Rook on your third rank until the pawn advances, then check from behind.",
              fen: "4k3/7R/r7/3PK3/8/8/8/8 b - - 0 1", goal: .hold(moves: 25), moveLimit: 25)
    ]
}

struct EndgamesView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var progress: ProgressStore

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: "Core endgames")
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Play them against full-strength Stockfish until you can do each one every time.")
                        .font(.bcBody).foregroundStyle(BC.mute).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4).padding(.bottom, 6)
                    ForEach(Array(EndgameDrill.all.enumerated()), id: \.element.id) { i, d in
                        Button { app.open(.endgame(d.id)) } label: { row(d) }
                            .buttonStyle(PressStyle())
                            .arrive(i)
                    }
                }
                .padding(.horizontal, BC.side).padding(.top, 8).padding(.bottom, 40)
                .readableColumn()
            }
            .scrollIndicators(.hidden)
        }
        .background(Spotlight(colour: app.tab.light, strength: 0.24))
    }

    private func row(_ d: EndgameDrill) -> some View {
        let n = progress.data.endgames[d.id] ?? 0
        return HStack(spacing: 12) {
            MiniBoard(fen: d.fen, size: 64, flipped: d.you == .black)
            VStack(alignment: .leading, spacing: 3) {
                Text(d.title).font(.bcRowTitle).foregroundStyle(BC.ink).lineLimit(1).minimumScaleFactor(0.85)
                Text(d.detail).font(.bcCaption).foregroundStyle(BC.mute).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Tag(text: d.kindTag.0, colour: d.kindTag.1)
                    Text(n == 0 ? "Not done yet" : "Done \(n)×").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(n == 0 ? BC.mute : BC.mint)
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.forward").font(.system(size: 13, weight: .semibold)).foregroundStyle(BC.mute)
        }
        .padding(11)
        .background(BC.card, in: RoundedRectangle(cornerRadius: BC.rRow, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BC.rRow, style: .continuous).stroke(BC.line, lineWidth: 1))
        .contentShape(Rectangle())
    }
}

struct EndgameDrillView: View {
    let drillID: String
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var progress: ProgressStore
    @StateObject private var board = BoardState()
    @StateObject private var line = LinePlayer()
    @State private var fen = ""
    @State private var bestUCI: String?
    @State private var movesMade = 0
    @State private var result: Bool? = nil
    @State private var message = ""
    @State private var thinking = false
    @State private var finding = false
    @State private var game = 0
    private static let owner = "endgame"

    private var drill: EndgameDrill? { EndgameDrill.all.first { $0.id == drillID } }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: drill?.title ?? "Endgame", subtitle: "Move \(min(movesMade + (result == nil ? 1 : 0), drill?.moveLimit ?? 0)) of \(drill?.moveLimit ?? 0)")
            BoardLayout(reserve: 270) { _ in
                Text(drill?.detail ?? "").font(.bcCaption).foregroundStyle(BC.mute)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, BC.side).padding(.top, 4).padding(.bottom, 12)
            } board: { size in
                BoardView(state: board, size: size)
            } panel: {
                card.padding(.horizontal, BC.side).padding(.top, 14)
                Spacer(minLength: 0)
                if result != nil {
                    BlockButton(title: "Play it again", systemImage: "arrow.counterclockwise") { reset() }
                        .padding(.horizontal, BC.side).padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .background(Spotlight(colour: result == true ? BC.mint : result == false ? BC.coral : app.tab.light, strength: 0.24))
        .animation(BC.curve(0.3), value: result)
        .onAppear { if fen.isEmpty { reset() } }
        .onDisappear {
            line.clear()
            Task { await EngineService.shared.stop(owner: Self.owner) }
        }
    }

    private var card: some View {
        let border = result == true ? BC.mint.opacity(0.45) : result == false ? BC.coral.opacity(0.45) : BC.line
        return CardBox(padding: 16, radius: BC.rRow, border: border) {
            VStack(alignment: .leading, spacing: 10) {
                LabelText(result == true ? "Done" : result == false ? "Not this time" : thinking ? "Stockfish is moving" : "Your move",
                          colour: result == true ? BC.mint : result == false ? BC.coral : thinking ? BC.violet : BC.blue)
                Text(message.isEmpty ? (drill?.goalText ?? "") : message)
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(BC.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if result == nil && line.isActive {
                    LineStrip(player: line)
                    Button { backToPosition() } label: { Label("Back to the position", systemImage: "arrow.uturn.backward") }
                        .buttonStyle(PillButton(filled: true))
                } else if result == nil {
                    HStack(spacing: 8) {
                        Button { showBest() } label: { Label("Best move", systemImage: "star") }
                            .buttonStyle(PillButton())
                            .disabled(thinking || finding)
                        Button { reset() } label: { Label("Restart", systemImage: "arrow.counterclockwise") }
                            .buttonStyle(PillButton())
                        Spacer(minLength: 0)
                        if thinking || finding { ProgressView().tint(BC.mute).controlSize(.small) }
                    }
                }
            }
        }
    }

    /// Stockfish's move here, and the line that shows why, played out. Then back to the position.
    private func showBest() {
        let f = fen
        finding = true
        Task { @MainActor in
            let top = await EngineService.shared.analyse(fen: f, depth: 20, owner: Self.owner).first
            finding = false
            guard f == fen, result == nil, !thinking, let top, let b = top.best, b.count >= 4 else { return }
            bestUCI = b
            message = "Stockfish plays \(Chess.play(b, on: f)?.san ?? b) here. Watch the line."
            Feel.tap()
            board.userColor = nil
            line.play(top.pv, from: f, on: board, colour: BC.mint, limit: 10)
        }
    }

    /// Leave the line: the position as it was, with the best move as an arrow, and your move again.
    private func backToPosition() {
        guard let d = drill else { return }
        line.clear()
        board.set(fen: fen, animated: true)
        board.clearMarks()
        if let b = bestUCI {
            board.arrows = [BoardArrow(from: String(b.prefix(2)), to: String(b.dropFirst(2).prefix(2)), colour: BC.mint)]
            message = "Your move. Stockfish's choice is \(Chess.play(b, on: fen)?.san ?? b)."
        }
        board.userColor = d.you
        Feel.tick()
    }

    private func reset() {
        guard let d = drill else { return }
        game += 1
        line.clear()
        bestUCI = nil
        Task { await EngineService.shared.stop(owner: Self.owner) }
        fen = d.fen
        movesMade = 0
        result = nil
        message = ""
        thinking = false
        finding = false
        board.flipped = d.you == .black
        board.showCoordinates = progress.settings.coordinates
        board.set(fen: fen, animated: false)
        board.clearMarks()
        board.userColor = d.you
        board.onMove = { from, to, promo in userMove(from: from, to: to, promo: promo) }
    }

    private func queens(_ f: String, _ c: PieceColor) -> Int { Chess.pieces(f).filter { $0.color == c && $0.kind == "Q" }.count }

    private func userMove(from: String, to: String, promo: Piece.Kind?) {
        guard result == nil, !thinking, let d = drill, let p = Chess.move(from: from, to: to, promotion: promo, on: fen) else { return }
        let before = fen
        apply(p)
        board.arrows = []
        movesMade += 1
        message = ""
        if check(d, before: before, afterUser: true) { return }
        thinking = true
        board.userColor = nil
        let target = fen
        let round = game
        Task { @MainActor in
            let best = await EngineService.shared.analyse(fen: target, depth: 16, owner: Self.owner).first?.best
            guard round == game else { return }
            thinking = false
            guard result == nil, fen == target, let best, let reply = Chess.play(best, on: target) else {
                board.userColor = d.you
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
            apply(reply)
            if check(d, before: target, afterUser: false) { return }
            board.userColor = d.you
        }
    }

    private func apply(_ p: Ply) {
        fen = p.fenAfter
        board.set(fen: fen, lastMove: MovePair(from: p.from, to: p.to))
        Feel.move(san: p.san)
    }

    /// True when the drill is over.
    private func check(_ d: EndgameDrill, before: String, afterUser: Bool) -> Bool {
        let outcome = Chess.outcome(fen)
        let me = d.you
        func end(_ ok: Bool, _ msg: String) -> Bool {
            result = ok
            message = msg
            board.userColor = nil
            if ok { Feel.complete(); progress.markEndgame(d.id) } else { Feel.wrong() }
            return true
        }
        switch d.goal {
        case .mate:
            if case .checkmate(let w) = outcome { return end(w == me, "Checkmate in \(movesMade) moves.") }
            if case .draw(let r) = outcome { return end(false, r == "stalemate" ? "Stalemate. Always leave the king a square." : "That's a draw.") }
            if !afterUser, movesMade >= d.moveLimit { return end(false, "Out of moves. Push the king to the edge faster.") }
        case .promote:
            if afterUser && queens(fen, me) > queens(before, me) { return end(true, "Promoted in \(movesMade) moves.") }
            if case .draw = outcome { return end(false, "It slipped into a draw.") }
            if Chess.pieces(fen).filter({ $0.color == me && $0.kind == "P" }).isEmpty && queens(fen, me) == 0 { return end(false, "The pawn is gone.") }
            if !afterUser, movesMade >= d.moveLimit { return end(false, "Out of moves.") }
        case .hold(let n):
            if queens(fen, me.opposite) > queens(before, me.opposite) { return end(false, "The pawn queened.") }
            if case .checkmate = outcome { return end(false, "Checkmated.") }
            if case .draw = outcome { return end(true, "A draw. You held it.") }
            if Chess.pieces(fen).filter({ $0.color == me.opposite && $0.kind == "P" }).isEmpty { return end(true, "You won the pawn. Draw held.") }
            if !afterUser, movesMade >= n { return end(true, "You held for \(n) moves.") }
        }
        return false
    }
}
