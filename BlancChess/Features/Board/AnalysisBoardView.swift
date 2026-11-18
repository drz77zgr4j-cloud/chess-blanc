import SwiftUI

/// The Board: one board, two modes. Analyse (engine lines or "judge my moves") and Play bot.
/// `start == nil` is the tab root (dock below); otherwise it was pushed from somewhere else.
struct AnalysisBoardView: View {
    let start: BoardStart?
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var progress: ProgressStore
    @StateObject private var model: BoardModel
    @State private var sheet: BoardSheet?
    @State private var onScreen = false
    @Environment(\.tabVisible) private var tabVisible

    enum BoardSheet: String, Identifiable {
        case explorer, setup, botStart, gameOver
        var id: String { rawValue }
    }

    init(start: BoardStart?) {
        self.start = start
        _model = StateObject(wrappedValue: start.map { BoardModel(start: $0) } ?? BoardModel.tabRoot)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let start { NavBar(title: start.title) }
            // The engine panel takes whatever the board leaves: at least a couple of lines.
            BoardLayout(reserve: 250) { _ in
                BoardHeader(model: model, isRoot: start == nil) { sheet = .botStart }
                    .padding(.horizontal, BC.side)
                    .padding(.top, start == nil ? 6 : 2)
                EnginePanel(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.horizontal, BC.side)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
            } board: { size in
                boardArea(size)
            } panel: {
                MoveStrip(model: model)
                toolbar
            }
        }
        .padding(.bottom, start == nil ? BC.dockClearance : 0)
        .background(Spotlight(colour: BC.violet))
        .sheet(item: $sheet) { s in sheetView(s) }
        .onAppear {
            onScreen = true
            model.configure(settings: progress.settings, book: app.book, reps: app.repertoires)
            if tabVisible { model.resume() }
        }
        .onDisappear {
            onScreen = false
            model.pause()
        }
        // Tabs stay alive when you switch away: stop thinking while this one is behind another.
        .onChange(of: tabVisible) { _, visible in
            guard onScreen else { return }
            if visible { model.resume() } else { model.pause() }
        }
        .onChange(of: progress.settings) { _, s in model.configure(settings: s, book: app.book, reps: app.repertoires) }
        .onChange(of: app.book != nil) { _, _ in model.configure(settings: progress.settings, book: app.book, reps: app.repertoires) }
        .onChange(of: model.gameOverCount) { _, _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 900_000_000)
                if model.result != nil, sheet == nil { sheet = .gameOver }
            }
        }
    }

    // MARK: Board

    private func boardArea(_ size: CGFloat) -> some View {
        BoardView(state: model.board, size: size)
            .overlay {
                if model.showingBest != nil {
                    BoardView(state: model.preview, size: size)
                        .overlay { Rectangle().stroke(BC.mint, lineWidth: 3).allowsHitTesting(false) }
                        .transition(.opacity)
                }
            }
    }

    // MARK: Toolbar

    @ViewBuilder
    private var toolbar: some View {
        if model.mode == .bot {
            BoardToolbar {
                ToolbarButton(title: "Take back", systemImage: "arrow.uturn.backward", enabled: model.canTakeBack) { model.takeBack() }
                ToolbarButton(title: "Flip", systemImage: "arrow.up.arrow.down") { model.flip() }
                ToolbarButton(title: "New game", systemImage: "plus") { sheet = .botStart }
                if model.result == nil {
                    Menu {
                        Button(role: .destructive) { model.resign() } label: { Label("Resign this game", systemImage: "flag") }
                    } label: {
                        ToolbarLabel(title: "Resign", systemImage: "flag")
                    }
                } else {
                    ToolbarButton(title: "Result", systemImage: "trophy") { sheet = .gameOver }
                }
            }
        } else {
            BoardToolbar {
                ToolbarButton(title: "Back", systemImage: "chevron.left", enabled: model.index > 0) { model.go(to: model.index - 1) }
                ToolbarButton(title: "Forward", systemImage: "chevron.right", enabled: model.index < model.plies.count) {
                    model.go(to: model.index + 1)
                }
                ToolbarButton(title: "Flip", systemImage: "arrow.up.arrow.down") { model.flip() }
                ToolbarButton(title: "Explorer", systemImage: "books.vertical") { sheet = .explorer }
                ToolbarButton(title: "Set up", systemImage: "square.grid.3x3") { sheet = .setup }
                Menu {
                    Section("Reset") {
                        Button { model.clearMoves() } label: { Label("Clear moves", systemImage: "arrow.counterclockwise") }
                        if start != nil {
                            Button { model.resetToStart() } label: { Label("Back to where it started", systemImage: "arrow.uturn.backward") }
                        }
                        Button { model.reset(fen: Chess.startFEN, flipped: false) } label: { Label("New board", systemImage: "square.grid.3x3.square") }
                    }
                    Section("Stockfish") {
                        if model.engineMode == .off {
                            Button { model.setEngineMode(.lines) } label: { Label("Turn the engine on", systemImage: "cpu") }
                        } else {
                            Button { model.setEngineMode(.off) } label: { Label("Turn the engine off", systemImage: "power") }
                        }
                    }
                } label: {
                    ToolbarLabel(title: "More", systemImage: "ellipsis.circle")
                }
            }
        }
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetView(_ s: BoardSheet) -> some View {
        switch s {
        case .explorer:
            ExplorerSheet(model: model)
                .presentationDetents([.medium, .large])
        case .setup:
            SetupSheet(fen: model.fen, flipped: model.board.flipped) { fen in
                model.reset(fen: fen)
            }
            .presentationDetents([.large])
        case .botStart:
            BotStartSheet(fen: model.fen, elo: progress.settings.botElo, hasGames: !app.games.games.isEmpty) { choice, elo, opponents in
                if progress.settings.botElo != elo { progress.settings.botElo = elo }
                if opponents && model.opponentBook == nil {
                    Task {
                        model.opponentBook = await OpponentBook.build(app.games.games)
                        model.startBot(choice: choice, elo: elo, opponents: true)
                    }
                } else {
                    model.startBot(choice: choice, elo: elo, opponents: opponents)
                }
            }
            .presentationDetents([.height(560)])
        case .gameOver:
            GameOverSheet(model: model) {
                model.rematch()
            } review: {
                model.analyse()
            }
            .presentationDetents([.height(GameOverSheet.height(model.result))])
        }
    }
}

/// A toolbar-shaped label for menus.
struct ToolbarLabel: View {
    let title: String
    let systemImage: String
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage).font(.system(size: 19, weight: .medium)).frame(height: 22)
            Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .foregroundStyle(BC.ink)
        .frame(maxWidth: .infinity, minHeight: 52)
        .contentShape(Rectangle())
    }
}

// MARK: - Header

/// Mode chips, the judge toggle and one small status line.
struct BoardHeader: View {
    @ObservedObject var model: BoardModel
    let isRoot: Bool
    let playBot: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 22) {
                modeTab("Analyse", on: model.mode == .analyse) { model.analyse() }
                modeTab("Play bot", on: model.mode == .bot) { if model.mode != .bot { playBot() } }
                Spacer(minLength: 0)
                if model.mode == .analyse {
                    judgeChip("Judge", on: model.engineMode == .judge)
                }
            }
            status
                .frame(height: 16)
        }
    }

    /// Blanc Notes Studio's text tabs: the word, and a short white line under the one you're on.
    private func modeTab(_ title: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button {
            guard !on else { return }
            Feel.tick()
            withAnimation(BC.curve(0.24)) { action() }
        } label: {
            VStack(spacing: 6) {
                Text(title).font(.system(size: 20, weight: .bold))
                    .foregroundStyle(on ? BC.ink : BC.mute.opacity(0.7))
                Capsule().fill(on ? BC.ink : .clear).frame(height: 3)
            }
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func judgeChip(_ title: String, on: Bool) -> some View {
        Button {
            Feel.tick()
            withAnimation(BC.curve(0.24)) { model.setEngineMode(on ? .lines : .judge) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: on ? "checkmark.seal.fill" : "checkmark.seal").font(.system(size: 12, weight: .semibold))
                Text(title).font(.bcChip).lineLimit(1)
            }
            .foregroundStyle(on ? .black : BC.ink)
            .padding(.horizontal, 14).frame(height: 38)
            .background(on ? BC.violet : BC.card, in: Capsule())
            .overlay(Capsule().stroke(on ? .clear : BC.line, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Judge my moves")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    @ViewBuilder
    private var status: some View {
        if model.mode == .bot, let g = model.game {
            HStack(spacing: 6) {
                Text(verbatim: g.opponents ? "You play \(g.side.name) · your opponents' openings · \(g.elo)"
                                           : "You play \(g.side.name) · Bot \(g.elo), \(BoardModel.eloLabel(g.elo).lowercased())")
                    .font(.bcCaption).foregroundStyle(BC.mute).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 6)
                botState
            }
        } else {
            HStack(spacing: 6) {
                let name = model.openingName ?? (model.index == 0 && model.root == Chess.startFEN ? "Starting position" : "Your position")
                // A long name falls back to its variation ("Advance Variation, Short Variation") rather than an ellipsis.
                ViewThatFits(in: .horizontal) {
                    statusText(name)
                    statusText(name.components(separatedBy: ": ").last ?? name)
                    statusText(name.components(separatedBy: ", ").last ?? name)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func statusText(_ t: String) -> some View {
        Text(t).font(.bcCaption).foregroundStyle(BC.mute).lineLimit(1).minimumScaleFactor(0.8)
            .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var botState: some View {
        if let r = model.result {
            Text(r.kind == .win ? "You won" : r.kind == .loss ? "You lost" : "Draw")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(r.kind == .win ? BC.mint : r.kind == .loss ? BC.coral : BC.ink)
                .fixedSize()
        } else if model.botThinking {
            HStack(spacing: 5) {
                PulseDot(colour: BC.violet)
                Text("Thinking").font(.system(size: 13, weight: .semibold)).foregroundStyle(BC.ink)
            }
            .fixedSize()
        } else if let g = model.game, model.sideToMove != g.side {
            HStack(spacing: 5) {
                Circle().fill(BC.coral).frame(width: 7, height: 7)
                Text("Bot to move").font(.system(size: 13, weight: .semibold)).foregroundStyle(BC.ink)
            }
            .fixedSize()
        } else {
            HStack(spacing: 5) {
                Circle().fill(BC.mint).frame(width: 7, height: 7)
                Text("Your move").font(.system(size: 13, weight: .semibold)).foregroundStyle(BC.ink)
            }
            .fixedSize()
        }
    }
}

/// A small dot that breathes while the bot thinks.
struct PulseDot: View {
    let colour: Color
    @State private var on = false
    var body: some View {
        Circle().fill(colour).frame(width: 7, height: 7)
            .opacity(on ? 1 : 0.35)
            .onAppear { withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { on = true } }
    }
}
