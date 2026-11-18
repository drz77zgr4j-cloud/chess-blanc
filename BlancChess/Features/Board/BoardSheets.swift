import SwiftUI

// MARK: - Explorer

/// What club players play here, offline. Tap a move to play it; the sheet follows along.
struct ExplorerSheet: View {
    @ObservedObject var model: BoardModel

    var body: some View {
        SheetChrome(title: "Explorer", colour: BC.violet) {
            let entry = model.bookEntry
            let mine = model.repertoireMove(at: model.fen)
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.openingName ?? (model.index == 0 ? "Starting position" : "No name here"))
                            .font(.bcCardTitle).foregroundStyle(BC.ink)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        Text(entry.map { "\($0.games.formatted()) club games · \(model.sideToMove.name) to move" }
                             ?? "\(model.sideToMove.name) to move")
                            .font(.bcCaption).foregroundStyle(BC.mute).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    Spacer(minLength: 8)
                    if model.index > 0 {
                        Button { model.go(to: model.index - 1) } label: { Label("Back", systemImage: "chevron.left") }
                            .buttonStyle(PillButton())
                    }
                }
                if let entry {
                    ScrollView {
                        RowGroup {
                            ForEach(entry.moves) { m in
                                ExplorerRow(move: m, share: entry.share(m), yours: m.uci == mine) {
                                    model.play(uci: m.uci)
                                }
                            }
                        }
                        LabelText("1.5 M Lichess games, rated 1000–1900", colour: BC.faint)
                            .padding(.top, 10).padding(.horizontal, 4)
                    }
                    .scrollIndicators(.hidden)
                } else {
                    EmptyCard(title: model.hasBook ? "Out of the book" : "Explorer not ready",
                              message: model.hasBook ? "Club players rarely reach this position. Stockfish knows it, though."
                                                     : "The opening statistics are still loading.",
                              actionTitle: model.index > 0 ? "Back one move" : nil,
                              action: model.index > 0 ? { model.go(to: model.index - 1) } : nil)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

struct ExplorerRow: View {
    let move: OpeningBook.Move
    let share: Double
    let yours: Bool
    let play: () -> Void

    var body: some View {
        Button { play() } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(move.san).font(.system(size: 16, weight: .bold)).foregroundStyle(BC.ink)
                    if yours {
                        Text("Your move").font(.system(size: 11, weight: .bold)).foregroundStyle(BC.blue)
                    }
                }
                .frame(width: 74, alignment: .leading)
                Text("\(max(1, Int((share * 100).rounded())))%")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(BC.mute)
                    .frame(width: 40, alignment: .trailing)
                ResultBar(white: move.white, draws: move.draws, black: move.black)
            }
            .frame(minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(move.san), \(Int((share * 100).rounded())) percent\(yours ? ", your move" : "")")
    }
}

/// White wins, draws, black wins as one bar.
struct ResultBar: View {
    let white: Int
    let draws: Int
    let black: Int

    var body: some View {
        let total = max(1, white + draws + black)
        let w = Double(white) / Double(total), d = Double(draws) / Double(total), b = Double(black) / Double(total)
        GeometryReader { g in
            HStack(spacing: 0) {
                Rectangle().fill(Color(hex: 0xF0F0F0)).frame(width: g.size.width * w)
                    .overlay(alignment: .leading) { label(w, ink: .black).padding(.leading, 5) }
                Rectangle().fill(Color(hex: 0x7A7A80)).frame(width: g.size.width * d)
                Rectangle().fill(Color(hex: 0x2E2E34))
                    .overlay(alignment: .trailing) { label(b, ink: BC.ink).padding(.trailing, 5) }
            }
        }
        .frame(height: 18)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    @ViewBuilder
    private func label(_ v: Double, ink: Color) -> some View {
        if v >= 0.16 {
            Text("\(Int((v * 100).rounded()))").font(.system(size: 10, weight: .heavy).monospacedDigit()).foregroundStyle(ink)
                .fixedSize()
        }
    }
}

// MARK: - Set up a position

private struct SetupPiece: Hashable {
    let color: PieceColor
    let kind: String
    var image: String { PieceSet.image("\(color.rawValue)\(kind)") }
}

/// Build any position: pick a piece or the eraser, tap or drag across squares.
struct SetupSheet: View {
    let fen: String
    let flipped: Bool
    let apply: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pieces: [String: SetupPiece] = [:]
    @State private var brush: SetupPiece? = SetupPiece(color: .white, kind: "P")
    @State private var side: PieceColor = .white
    @State private var painted: Set<String> = []
    @State private var loaded = false

    var body: some View {
        SheetChrome(title: "Set up", colour: BC.violet) {
            VStack(spacing: 14) {
                palette
                grid
                HStack(spacing: 8) {
                    Chip(title: "White to move", dot: .white, active: side == .white) { side = .white }
                    Chip(title: "Black to move", dot: Color(hex: 0x3A3A40), active: side == .black) { side = .black }
                    Spacer(minLength: 0)
                }
                Text(problem ?? castlingText)
                    .font(.bcCaption)
                    .foregroundStyle(problem == nil ? BC.mute : BC.coral)
                    .lineLimit(2).minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
                HStack(spacing: 8) {
                    Button("Start position") { Feel.tick(); load(Chess.startFEN) }.buttonStyle(PillButton())
                    Button("Clear") { Feel.tick(); pieces = [:] }.buttonStyle(PillButton())
                    Spacer(minLength: 0)
                }
                BlockButton(title: "Analyse this position", enabled: problem == nil) {
                    apply(currentFEN)
                    dismiss()
                }
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            load(fen)
        }
    }

    // MARK: Palette

    private var palette: some View {
        HStack(spacing: 8) {
            VStack(spacing: 6) {
                paletteRow(.white)
                paletteRow(.black)
            }
            Button { Feel.tick(); brush = nil } label: {
                VStack(spacing: 4) {
                    Image(systemName: "eraser").font(.system(size: 18, weight: .semibold))
                    Text("Erase").font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(brush == nil ? BC.ink : BC.mute)
                .frame(width: 44, height: 94)
                .background(brush == nil ? BC.violet.opacity(0.28) : BC.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(brush == nil ? BC.violet : BC.line, lineWidth: brush == nil ? 2 : 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Eraser")
        }
        .frame(maxWidth: .infinity)
    }

    private func paletteRow(_ color: PieceColor) -> some View {
        HStack(spacing: 6) {
            ForEach(["K", "Q", "R", "B", "N", "P"], id: \.self) { k in
                let p = SetupPiece(color: color, kind: k)
                let on = brush == p
                Button { Feel.tick(); brush = p } label: {
                    Image(p.image).resizable().interpolation(.high).frame(width: 36, height: 36)
                        .frame(width: 44, height: 44)
                        .background(BC.lightSquare.opacity(on ? 1 : 0.82), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(on ? BC.violet : .clear, lineWidth: 3))
                        .scaleEffect(on ? 1.04 : 1)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(color.name) \(Self.kindName(k))")
            }
        }
    }

    // MARK: Board

    private var grid: some View {
        let size: CGFloat = 320
        let q = size / 8
        return ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                for row in 0..<8 {
                    for col in 0..<8 {
                        let f = flipped ? 7 - col : col
                        let r = flipped ? row + 1 : 8 - row
                        let rect = CGRect(x: CGFloat(col) * q, y: CGFloat(row) * q, width: q, height: q)
                        ctx.fill(Path(rect), with: .color((f + r) % 2 == 0 ? BC.lightSquare : BC.darkSquare))
                    }
                }
            }
            ForEach(Array(pieces.keys), id: \.self) { sq in
                if let p = pieces[sq] {
                    Image(p.image).resizable().interpolation(.high)
                        .frame(width: q, height: q)
                        .position(center(sq, q: q))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    guard let sq = square(at: v.location, q: q), !painted.contains(sq) else { return }
                    let first = painted.isEmpty
                    painted.insert(sq)
                    paint(sq, toggle: first)
                }
                .onEnded { _ in painted = [] }
        )
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Set-up board")
    }

    private func paint(_ sq: String, toggle: Bool) {
        if let b = brush {
            if toggle, pieces[sq] == b { pieces[sq] = nil } else { pieces[sq] = b }
        } else {
            pieces[sq] = nil
        }
        Feel.tick()
    }

    private func center(_ sq: String, q: CGFloat) -> CGPoint {
        let f = CGFloat(Int(sq.unicodeScalars.first!.value) - 97)
        let r = CGFloat(Int(String(sq.last!)) ?? 1)
        let col = flipped ? 7 - f : f
        let row = flipped ? r - 1 : 8 - r
        return CGPoint(x: (col + 0.5) * q, y: (row + 0.5) * q)
    }

    private func square(at p: CGPoint, q: CGFloat) -> String? {
        guard p.x >= 0, p.y >= 0, p.x < q * 8, p.y < q * 8 else { return nil }
        var col = Int(p.x / q), row = Int(p.y / q)
        if flipped { col = 7 - col; row = 7 - row }
        return "\(Array("abcdefgh")[col])\(8 - row)"
    }

    // MARK: Rules

    private func load(_ fen: String) {
        var map: [String: SetupPiece] = [:]
        for p in Chess.pieces(fen) { map[p.square] = SetupPiece(color: p.color, kind: p.kind) }
        pieces = map
        side = Chess.sideToMove(fen)
    }

    private func fen(toMove: PieceColor) -> String {
        Chess.fen(from: pieces.mapValues { ($0.color, $0.kind) }, sideToMove: toMove)
    }

    private var currentFEN: String { fen(toMove: side) }

    /// Why this position can't be played, if it can't.
    private var problem: String? {
        let kings = pieces.values.filter { $0.kind == "K" }
        if kings.filter({ $0.color == .white }).count != 1 || kings.filter({ $0.color == .black }).count != 1 {
            return "Each side needs exactly one king."
        }
        if pieces.contains(where: { $0.value.kind == "P" && ($0.key.hasSuffix("1") || $0.key.hasSuffix("8")) }) {
            return "Pawns can't stand on the first or last rank."
        }
        if Chess.inCheck(fen(toMove: side.opposite)) {
            return "\(side.opposite.name) is in check, so it can't be \(side.name)'s move."
        }
        if Chess.position(currentFEN) == nil || EngineService.safeFEN(currentFEN) == nil {
            return "That position isn't valid."
        }
        return nil
    }

    private var castlingText: String {
        let rights = currentFEN.split(separator: " ").dropFirst(2).first.map(String.init) ?? "-"
        func list(_ k: Character, _ q: Character) -> String {
            let s = [rights.contains(k) ? "O-O" : nil, rights.contains(q) ? "O-O-O" : nil].compactMap { $0 }
            return s.isEmpty ? "none" : s.joined(separator: ", ")
        }
        return "Castling · White \(list("K", "Q")) · Black \(list("k", "q")). Worked out from where the kings and rooks stand."
    }

    private static func kindName(_ k: String) -> String {
        switch k { case "K": "king"; case "Q": "queen"; case "R": "rook"; case "B": "bishop"; case "N": "knight"; default: "pawn" }
    }
}

// MARK: - Play the bot

struct BotStartSheet: View {
    let fen: String
    let start: (BoardModel.SideChoice, Int, Bool) -> Void
    var hasGames = false
    @Environment(\.dismiss) private var dismiss
    @State private var elo: Int
    @State private var choice: BoardModel.SideChoice
    @AppStorage("bot.opponents") private var opponents = true

    init(fen: String, elo: Int, hasGames: Bool, start: @escaping (BoardModel.SideChoice, Int, Bool) -> Void) {
        self.hasGames = hasGames
        self.fen = fen
        self.start = start
        _elo = State(initialValue: min(2800, max(400, elo)))
        _choice = State(initialValue: Chess.sideToMove(fen) == .white ? .white : .black)
    }

    var body: some View {
        SheetChrome(title: "Play the bot", colour: BC.violet) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    MiniBoard(fen: fen, size: 64, flipped: choice == .black, radius: 8)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(fen == Chess.startFEN ? "From the start" : "From this position")
                            .font(.bcRowTitle).foregroundStyle(BC.ink)
                        Text("Every move you play gets marked.").font(.bcCaption).foregroundStyle(BC.mute)
                    }
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 10) {
                    LabelText("You play")
                    ChipPicker(options: [(BoardModel.SideChoice.white, "White"), (.black, "Black"), (.random, "Random")],
                               selection: $choice, scrolls: false)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        LabelText("Strength")
                        Spacer()
                        Text(verbatim: "\(elo)").font(.system(size: 17, weight: .bold).monospacedDigit()).foregroundStyle(BC.ink)
                            .contentTransition(.numericText())
                        Text(BoardModel.eloLabel(elo)).font(.bcCaption).foregroundStyle(BC.mute)
                    }
                    Slider(value: Binding(get: { Double(elo) }, set: { v in
                        let n = Int((v / 100).rounded()) * 100
                        if n != elo { elo = n; Feel.tick() }
                    }), in: 400...2800, step: 100)
                    .tint(BC.violet)
                }
                if hasGames && fen == Chess.startFEN {
                    Toggle(isOn: $opponents) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Play like my opponents").font(.bcRowTitle).foregroundStyle(BC.ink)
                            Text("Opens with the lines people play against you").font(.bcCaption).foregroundStyle(BC.mute)
                        }
                    }
                    .tint(BC.violet)
                }
                BlockButton(title: "Play", systemImage: "play.fill") {
                    start(choice, elo, opponents && hasGames && fen == Chess.startFEN)
                    dismiss()
                }
            }
        }
    }
}

// MARK: - Game over

struct GameOverSheet: View {
    @ObservedObject var model: BoardModel
    let rematch: () -> Void
    let review: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetChrome(title: "Game over", colour: BC.violet) {
            if let r = model.result {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 12) {
                            IconTile(systemImage: icon(r), colour: colour(r), size: 48)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title(r)).font(.bcSheetTitle).foregroundStyle(colour(r))
                                Text(r.reason).font(.bcBody).foregroundStyle(BC.mute).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }
                        HStack(spacing: 10) {
                            StatCard(label: "Accuracy", value: r.accuracy.map { "\(Int($0.rounded()))%" } ?? "–",
                                     context: "your moves", colour: BC.ink)
                            StatCard(label: "Moves", value: "\(r.moves)", context: "you played")
                        }
                        let marks = MoveClass.reviewOrder.compactMap { c in r.counts[c].map { (c, $0) } }
                        if !marks.isEmpty {
                            SectionBox(title: "Your marks") {
                                CardBox(padding: 14) {
                                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                                        ForEach(marks, id: \.0) { c, n in
                                            HStack(spacing: 8) {
                                                ClassBadge(cls: c, size: 22)
                                                Text(c.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(BC.ink)
                                                    .lineLimit(1).minimumScaleFactor(0.8)
                                                Spacer(minLength: 4)
                                                Text("\(n)").font(.system(size: 14, weight: .bold).monospacedDigit()).foregroundStyle(c.colour)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        VStack(spacing: 10) {
                            BlockButton(title: "Rematch", systemImage: "arrow.clockwise") { dismiss(); rematch() }
                            SecondaryButton(title: "Review moves", systemImage: "magnifyingglass") { dismiss(); review() }
                        }
                        .padding(.top, 4)
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    /// Tall enough for what it shows, never more.
    static func height(_ r: BoardModel.GameResult?) -> CGFloat {
        let kinds = r?.counts.count ?? 0
        let marks: CGFloat = kinds == 0 ? 0 : 66 + CGFloat((kinds + 1) / 2) * 32
        return 470 + marks
    }

    private func title(_ r: BoardModel.GameResult) -> String {
        switch r.kind { case .win: "You won"; case .loss: "You lost"; case .draw: "Draw" }
    }
    private func icon(_ r: BoardModel.GameResult) -> String {
        switch r.kind { case .win: "trophy.fill"; case .loss: "flag.fill"; case .draw: "equal" }
    }
    private func colour(_ r: BoardModel.GameResult) -> Color {
        switch r.kind { case .win: BC.mint; case .loss: BC.coral; case .draw: BC.ink }
    }
}
