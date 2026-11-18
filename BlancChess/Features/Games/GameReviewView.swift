import SwiftUI
import ChessKit

/// Game review: a summary first (accuracy, graph, marks, opening), then one board to step through it.
struct GameReviewView: View {
    let gameID: String
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: GameStore
    @EnvironmentObject var progress: ProgressStore

    @StateObject private var board = BoardState()
    @StateObject private var line = LinePlayer()
    @State private var data: GameReviewData?
    @State private var reviewedAt: Date?
    @State private var reviewing = false
    @State private var idx = 0
    @State private var panel: Panel = .move
    @State private var cycle: [MoveClass: Int] = [:]
    @State private var focus: Focus?
    @State private var scrub: Int?
    @State private var retryTask: Task<Void, Never>?
    /// Your mistakes, misses and blunders in this game: positions to fix.
    @State private var slipCount = 0

    private static let owner = "game-review"
    private let coachHeight: CGFloat = 172

    enum Panel: Equatable {
        case move
        case best
        case why
        case retry(Retry)
    }

    enum Retry: Equatable {
        case waiting
        case checking(String)
        case solved(String, String)
        case wrong(String, String)
    }

    /// "Blunder 1 of 2" or "Key moment 3 of 7": what the coach's small chip steps through.
    struct Focus: Equatable {
        enum Kind: Equatable { case mark(MoveClass), key }
        let kind: Kind
        let pos: Int
        let of: Int
    }

    private var game: GameRecord? { store.game(gameID) }

    var body: some View {
        ZStack {
            if let g = game, let d = data {
                if reviewing && d.ready {
                    reviewScreen(g, d).transition(.opacity)
                } else {
                    summaryScreen(g, d).transition(.opacity)
                }
            } else if let g = game {
                // First frame, before the review data is set up: the bar is there from the start.
                VStack(spacing: 0) {
                    NavBar(back: "Games", title: "vs \(g.opponent)", subtitle: resultLine(g))
                    Spacer()
                }
            } else {
                VStack(spacing: 0) {
                    NavBar(back: "Games", title: "Game")
                    EmptyCard(title: "Game not found", message: "It may be outside your history window. Change the range on Games.")
                        .padding(BC.side)
                    Spacer()
                }
            }
        }
        .background(Spotlight(colour: glow))
        .onAppear(perform: setup)
        .onDisappear {
            line.clear()
            retryTask?.cancel()
            Task { await EngineService.shared.stop(owner: Self.owner) }
        }
        .onChange(of: store.revision) { _, _ in refreshData() }
        // Follows the reviewer without redrawing this whole screen on every progress tick.
        .background {
            ReviewStatusReader(status: store.live) { live in
                Color.clear.onChange(of: live.reviewingID) { _, now in
                    // A review just landed (maybe this game's): show it now, not at the next revision.
                    refreshData()
                    // If the queue was stopped elsewhere, ask again: this screen needs its review.
                    if now == nil, data?.ready == false, live.pending == 0 { store.reviewNow(gameID) }
                }
            }
        }
    }

    private var glow: Color { game?.result == .loss ? BC.coral : BC.mint }

    // MARK: Setup

    private func setup() {
        guard data == nil, let g = game else { return }
        data = GameReviewData(game: g, reps: app.repertoires)
        reviewedAt = g.review?.reviewedAt
        countSlips(g)
        board.flipped = g.userColor == .black
        board.showCoordinates = progress.settings.coordinates
        if g.review?.version != GameReview.currentVersion { store.reviewNow(gameID) }
    }

    private func refreshData() {
        guard let g = game, let d = data, g.review?.reviewedAt != reviewedAt else { return }
        reviewedAt = g.review?.reviewedAt
        let fresh = GameReviewData(game: g, reps: app.repertoires, previous: d)
        withAnimation(BC.curve(0.4)) { data = fresh }
        countSlips(g)
        if fresh.ready && !d.ready { Feel.next() }
    }

    private func countSlips(_ g: GameRecord) {
        slipCount = g.review?.version == GameReview.currentVersion ? Insights.mistakes(games: [g]).count : 0
    }

    private func resultLine(_ g: GameRecord) -> String {
        let r = g.result == .win ? "Won" : g.result == .loss ? "Lost" : "Drew"
        return "\(r) · \(g.timeClass.capitalized) · \(g.endTime.formatted(.relative(presentation: .named)))"
    }

    // MARK: - Summary

    private func summaryScreen(_ g: GameRecord, _ d: GameReviewData) -> some View {
        VStack(spacing: 0) {
            NavBar(back: "Games", title: "vs \(g.opponent)", subtitle: resultLine(g))
            ScrollView {
                VStack(spacing: 12) {
                    players(g, d).arrive(0)
                    graphCard(g, d).arrive(1)
                    marksTable(g, d).arrive(2)
                    openingCard(g, d).arrive(3)
                }
                .opacity(d.ready ? 1 : 0.35)
                .allowsHitTesting(d.ready)
                .padding(.horizontal, BC.side)
                .padding(.top, 8)
                .padding(.bottom, 20)
                .readableColumn()
            }
            .scrollIndicators(.hidden)
            .scrollDisabled(!d.ready)
            Group {
                if d.ready {
                    VStack(spacing: 2) {
                        BlockButton(title: "Start review", systemImage: "play.fill") { startReview(at: 0) }
                        if slipCount > 0 {
                            QuietButton(title: "Fix this game's mistakes (\(slipCount))") {
                                app.open(.puzzles(PuzzleSet(source: .game(g.id), title: "This game's mistakes")))
                            }
                        }
                    }
                } else {
                    pendingCard
                }
            }
            .padding(.horizontal, BC.side)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .readableColumn()
        }
    }

    private var pendingCard: some View {
        ReviewStatusReader(status: store.live) { live in pendingCard(live) }
    }

    private func pendingCard(_ live: ReviewStatus) -> some View {
        let mine = live.reviewingID == gameID
        let p = mine ? live.progress : 0
        return CardBox(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(mine ? "Stockfish is reviewing this game" : "Waiting for Stockfish")
                        .font(.bcBodyStrong).foregroundStyle(BC.ink).lineLimit(1).minimumScaleFactor(0.85)
                    Spacer(minLength: 8)
                    Text("\(Int((p * 100).rounded()))%").font(.system(size: 14, weight: .semibold).monospacedDigit()).foregroundStyle(BC.mute)
                }
                ProgressBar(value: p, colour: BC.violet)
                Text(mine ? "Every move gets its mark. Usually under a minute." : "It finishes the game it's on, then this one.")
                    .font(.bcCaption).foregroundStyle(BC.mute)
            }
        }
    }

    private func players(_ g: GameRecord, _ d: GameReviewData) -> some View {
        let r = d.review
        let mineAcc = r.map { g.userColor == .white ? $0.accuracyWhite : $0.accuracyBlack }
        let theirAcc = r.map { g.userColor == .white ? $0.accuracyBlack : $0.accuracyWhite }
        return CardBox(padding: 16) {
            HStack(spacing: 0) {
                playerColumn(name: "You", rating: g.userRating, side: g.userColor, acc: mineAcc, bright: true)
                Rectangle().fill(BC.line).frame(width: 1, height: 70)
                playerColumn(name: g.opponent, rating: g.opponentRating, side: g.userColor.opposite, acc: theirAcc, bright: false)
            }
        }
    }

    private func playerColumn(name: String, rating: Int, side: PieceColor, acc: Double?, bright: Bool) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(side == .white ? Color.white : Color(hex: 0x3A3A40))
                    .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
                    .frame(width: 10, height: 10)
                Text(name).font(.system(size: 14, weight: .semibold)).foregroundStyle(bright ? BC.ink : BC.mute).lineLimit(1)
                Text("\(rating)").font(.system(size: 13).monospacedDigit()).foregroundStyle(BC.mute).fixedSize()
            }
            .padding(.horizontal, 6)
            Text(acc.map { String(format: "%.1f", $0) } ?? "–")
                .font(.system(size: 40, weight: .bold).monospacedDigit()).tracking(-1)
                .foregroundStyle(bright ? BC.ink : BC.mute)
                .lineLimit(1).minimumScaleFactor(0.7)
            LabelText("Accuracy")
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func graphCard(_ g: GameRecord, _ d: GameReviewData) -> some View {
        CardBox(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    LabelText("Evaluation")
                    Spacer()
                    Text(scrubText(d)).font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(scrub == nil ? BC.mute : BC.ink).lineLimit(1)
                }
                ReviewEvalGraph(data: d, cursor: scrub, height: 84) { k in
                    scrub = k
                } onCommit: { k in
                    scrub = nil
                    focus = nil
                    startReview(at: k)
                }
            }
        }
    }

    private func scrubText(_ d: GameReviewData) -> String {
        guard let k = scrub else { return "Tap to jump to a move" }
        if k == 0 { return "Start · \(d.evalText(at: 0))" }
        let c = d.cls(k - 1)
        return "\(d.numbered[k - 1])\(c.map { $0.isTop || $0.isSlip ? " \($0.symbol)" : "" } ?? "") · \(d.evalText(at: k))"
    }

    private func marksTable(_ g: GameRecord, _ d: GameReviewData) -> some View {
        CardBox(padding: 16) {
            VStack(spacing: 0) {
                HStack {
                    Text("You").font(.system(size: 14, weight: .bold)).foregroundStyle(BC.ink)
                    Spacer()
                    Text(g.opponent).font(.system(size: 14, weight: .semibold)).foregroundStyle(BC.mute).lineLimit(1)
                        .frame(maxWidth: 130, alignment: .trailing)
                }
                .padding(.bottom, 6)
                ForEach(MoveClass.reviewOrder) { c in
                    markRow(c, d)
                }
            }
        }
    }

    private func markRow(_ c: MoveClass, _ d: GameReviewData) -> some View {
        let mine = d.mine[c] ?? 0
        let theirs = d.theirs[c] ?? 0
        return Button { jump(to: c) } label: {
            HStack(spacing: 0) {
                Text(d.ready ? "\(mine)" : "–").font(.system(size: 17, weight: .bold).monospacedDigit())
                    .foregroundStyle(mine > 0 ? c.colour : BC.faint)
                    .frame(width: 52, alignment: .leading)
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    ClassBadge(cls: c, size: 22)
                    Text(c.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(mine > 0 ? BC.ink : BC.mute)
                }
                .frame(width: 140, alignment: .leading)
                Spacer(minLength: 0)
                Text(d.ready ? "\(theirs)" : "–").font(.system(size: 17, weight: .semibold).monospacedDigit())
                    .foregroundStyle(theirs > 0 ? BC.mute : BC.faint)
                    .frame(width: 52, alignment: .trailing)
            }
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .disabled(mine == 0)
        .accessibilityLabel("\(c.title): you \(mine), them \(theirs)")
    }

    private func openingCard(_ g: GameRecord, _ d: GameReviewData) -> some View {
        CardBox {
            VStack(alignment: .leading, spacing: 6) {
                LabelText("Opening")
                Text(g.opening).font(.bcCardTitle).foregroundStyle(BC.ink).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if let t = d.prepText {
                    Text(t).font(.bcCaption).foregroundStyle(BC.mute).fixedSize(horizontal: false, vertical: true)
                }
                if let p = d.prep, let node = p.lastNode {
                    Button {
                        Feel.tick()
                        app.open(.explore(rep: p.repertoire.id, node: node.id))
                    } label: {
                        HStack(spacing: 4) {
                            Text("See it in your repertoire")
                            Image(systemName: "chevron.forward").font(.system(size: 11, weight: .bold))
                        }
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(BC.blue)
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Review mode

    private func reviewScreen(_ g: GameRecord, _ d: GameReviewData) -> some View {
        // Everything but the board has a fixed height, so nothing jumps as you step through.
        let fixed: CGFloat = 34 + 10 + coachHeight + 8 + 32 + 8 + 53
        return VStack(spacing: 0) {
            NavBar(back: "Summary", title: "vs \(g.opponent)", subtitle: resultLine(g), onBack: exitReview)
            BoardLayout(reserve: fixed) { width in
                // While you look at the better move (best line, retry), the bar shows the position before it.
                let e = d.eval(at: showingBefore ? max(0, idx - 1) : idx)
                EvalBar(cp: e.cp, mate: e.mate)
                    .frame(width: width - 16)
                    .padding(.vertical, 6)
            } board: { size in
                BoardView(state: board, size: size)
            } panel: {
                coach(g, d)
                    .frame(height: coachHeight)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                moveStrip(d)
                    .frame(height: 32)
                    .padding(.vertical, 8)
                Spacer(minLength: 0)
                toolbar(g, d)
            }
        }
    }

    private var showingBefore: Bool {
        switch panel {
        case .best, .retry: return true
        default: return false
        }
    }

    private func toolbar(_ g: GameRecord, _ d: GameReviewData) -> some View {
        BoardToolbar {
            ToolbarButton(title: "Previous", systemImage: "chevron.left", enabled: idx > 0) { go(idx - 1) }
            ToolbarButton(title: "Next", systemImage: "chevron.right", enabled: idx < d.plies) { go(idx + 1) }
            ToolbarButton(title: "Key moment", systemImage: "sparkles", enabled: !d.keyPlies.isEmpty) { nextKeyMoment() }
            ToolbarButton(title: "Flip", systemImage: "arrow.up.arrow.down") {
                withAnimation(BC.curve(0.35)) { board.flipped.toggle() }
            }
            ToolbarButton(title: "Analyse", systemImage: "magnifyingglass") {
                line.clear()
                // Pushed here on Games, so Back comes back to this review.
                app.open(.board(BoardStart(fen: g.startFEN, history: Array(d.ucis.prefix(idx)),
                                                 title: "vs \(g.opponent)", flipped: board.flipped)))
            }
        }
    }

    // MARK: Coach

    private func coach(_ g: GameRecord, _ d: GameReviewData) -> some View {
        let tint = coachTint(d)
        return VStack(alignment: .leading, spacing: 0) {
            switch panel {
            case .move: movePanel(g, d)
            case .best, .why: linePanel(g, d)
            case .retry(let r): retryPanel(g, d, r)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(BC.card, in: RoundedRectangle(cornerRadius: BC.rRow, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BC.rRow, style: .continuous).stroke(tint, lineWidth: 1))
        .animation(BC.curve(0.25), value: panel)
    }

    private func coachTint(_ d: GameReviewData) -> Color {
        switch panel {
        case .retry(.solved): return BC.mint.opacity(0.5)
        case .retry(.wrong): return BC.coral.opacity(0.5)
        case .move:
            if idx > 0, let c = d.cls(idx - 1), c.isSlip || c == .brilliant || c == .great { return c.colour.opacity(0.45) }
            return BC.line
        default: return BC.line
        }
    }

    @ViewBuilder
    private func movePanel(_ g: GameRecord, _ d: GameReviewData) -> some View {
        if idx == 0 {
            HStack(spacing: 10) {
                IconTile(systemImage: "flag.fill", colour: BC.mint, size: 30)
                Text("Start of the game").font(.system(size: 17, weight: .bold)).foregroundStyle(BC.ink).lineLimit(1)
            }
            Text(g.opening).font(.system(size: 14, weight: .semibold)).foregroundStyle(BC.mute).lineLimit(1)
                .minimumScaleFactor(0.8).padding(.top, 8)
            Text("Step through with Next, or jump to the moves that mattered with Key moment.")
                .font(.system(size: 14)).foregroundStyle(Color(hex: 0xD2D2D6)).lineLimit(3).padding(.top, 4)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Button("First move") { go(1) }.buttonStyle(PillButton(filled: true))
                if !d.keyPlies.isEmpty { Button("Key moment") { nextKeyMoment() }.buttonStyle(PillButton()) }
            }
        } else if let c = d.cls(idx - 1), let words = d.coach(idx - 1, opponent: g.opponent) {
            let i = idx - 1
            HStack(spacing: 10) {
                ClassBadge(cls: c, size: 28)
                Text(words.headline).font(.system(size: 17, weight: .bold)).foregroundStyle(BC.ink)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                if let f = focus {
                    Button {
                        if case .mark(let m) = f.kind { jump(to: m) } else { nextKeyMoment() }
                    } label: {
                        HStack(spacing: 3) {
                            Text("\(f.pos) of \(f.of)")
                            Image(systemName: "chevron.forward").font(.system(size: 10, weight: .bold))
                        }
                        .font(.system(size: 12, weight: .bold).monospacedDigit()).foregroundStyle(BC.ink)
                        .padding(.horizontal, 10).frame(height: 28)
                        .background(BC.raised, in: Capsule())
                    }
                    .buttonStyle(PressStyle())
                    .accessibilityLabel(f.kind == .key ? "Next key moment" : "Next of this mark")
                }
            }
            Text(detailLine(d, i, words))
                .font(.system(size: 14)).foregroundStyle(Color(hex: 0xD2D2D6))
                .lineLimit(3).minimumScaleFactor(0.85).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            Spacer(minLength: 0)
            moveButtons(g, d, i, c)
        }
    }

    private func detailLine(_ d: GameReviewData, _ i: Int, _ words: Coach.Line) -> String {
        if d.bookExit == i, d.cls(i) != .book {
            return "Out of book: the first move off well-known theory. " + words.detail
        }
        return words.detail
    }

    private func moveButtons(_ g: GameRecord, _ d: GameReviewData, _ i: Int, _ c: MoveClass) -> some View {
        let hasBest = d.betterMove(i) != nil && !(d.review?.bestLines[safe: i] ?? []).isEmpty
        let hasWhy = !(d.review?.bestLines[safe: i + 1] ?? []).isEmpty && c != .book && c != .forced
        let canRetry = c.isSlip && d.movers[i] == d.userColor
        return HStack(spacing: 8) {
            if hasBest {
                Button("Best") { playBest(d, i) }.buttonStyle(PillButton(filled: true))
            }
            if hasWhy {
                Button(c == .brilliant ? "Why it's brilliant" : "Show why") { playWhy(d, i) }
                    .buttonStyle(PillButton(filled: !hasBest))
            }
            if canRetry {
                Button("Retry") { startRetry(d, i) }.buttonStyle(PillButton())
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func linePanel(_ g: GameRecord, _ d: GameReviewData) -> some View {
        let i = idx - 1
        let best = panel == .best
        let c = d.cls(i) ?? .good
        HStack {
            LabelText(best ? "Best line" : (c == .brilliant ? "Why it's brilliant" : "Why"), colour: best ? BC.best : c.colour)
            Spacer()
            Button("Done") { Feel.tick(); backToMove() }
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(BC.mute)
                .frame(minHeight: 30)
        }
        Text(lineExplanation(d, i, best: best))
            .font(.system(size: 14)).foregroundStyle(Color(hex: 0xD2D2D6))
            .lineLimit(3).minimumScaleFactor(0.85).fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
        Spacer(minLength: 0)
        LineStrip(player: line)
    }

    private func lineExplanation(_ d: GameReviewData, _ i: Int, best: Bool) -> String {
        guard i >= 0, let r = d.review else { return "" }
        let san = d.sans[i]
        if best {
            let b = r.best[safe: i].flatMap { Chess.play($0, on: d.fens[i])?.san } ?? "The best move"
            return "\(b) instead of \(san). Stockfish's line keeps it at \(d.evalText(at: i)) instead of \(d.evalText(at: i + 1))."
        }
        let reply = r.bestLines[safe: i + 1]?.first.flatMap { Chess.play($0, on: d.fens[i + 1])?.san }
        let c = d.cls(i) ?? .good
        let mine = d.movers[i] == d.userColor
        if c == .brilliant {
            return "\(san) gives up material, and the line shows how it comes back. It ends at \(d.evalText(at: i + 1))."
        }
        if c.isSlip, let reply {
            let theme = (r.themes?[safe: i]) ?? nil
            let gain: String
            switch theme {
            case .hungPiece?, .lostMaterial?: gain = " and win material"
            case .allowedMate?: gain = " and force mate"
            default: gain = ""
            }
            let who = mine ? "they answer" : "you could answer"
            return "After \(san), \(who) \(reply)\(gain). The eval goes from \(d.evalText(at: i)) to \(d.evalText(at: i + 1))."
        }
        if let reply {
            return "After \(san), Stockfish expects \(reply). The position stays at \(d.evalText(at: i + 1))."
        }
        return "What happens after \(san)."
    }

    @ViewBuilder
    private func retryPanel(_ g: GameRecord, _ d: GameReviewData, _ r: Retry) -> some View {
        let i = idx - 1
        switch r {
        case .waiting, .checking:
            HStack(spacing: 10) {
                IconTile(systemImage: "arrow.uturn.backward", colour: BC.blue, size: 30)
                Text("Find a better move").font(.system(size: 17, weight: .bold)).foregroundStyle(BC.ink).lineLimit(1)
                Spacer()
            }
            Group {
                if case .checking(let san) = r {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(BC.violet)
                        Text("Checking \(san) with Stockfish…").foregroundStyle(BC.ink)
                    }
                } else {
                    Text("You played \(d.sans[i]) here. Play something better on the board.")
                        .foregroundStyle(Color(hex: 0xD2D2D6))
                }
            }
            .font(.system(size: 14)).lineLimit(2).padding(.top, 8)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Button("Show best") { playBest(d, i) }.buttonStyle(PillButton())
                Button("Cancel") { backToMove() }.buttonStyle(PillButton())
                Spacer(minLength: 0)
            }
        case .solved(let san, let text):
            HStack(spacing: 10) {
                Image(systemName: "checkmark").font(.system(size: 14, weight: .heavy)).foregroundStyle(.black)
                    .frame(width: 28, height: 28).background(BC.mint, in: Circle())
                Text("\(san) works").font(.system(size: 17, weight: .bold)).foregroundStyle(BC.mint).lineLimit(1)
                Spacer()
            }
            Text(text).font(.system(size: 14)).foregroundStyle(Color(hex: 0xD2D2D6)).lineLimit(3).padding(.top, 8)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Button("Done") { backToMove() }.buttonStyle(PillButton(filled: true))
                Button("Best line") { playBest(d, i) }.buttonStyle(PillButton())
                Spacer(minLength: 0)
            }
        case .wrong(let san, let text):
            HStack(spacing: 10) {
                Image(systemName: "xmark").font(.system(size: 14, weight: .heavy)).foregroundStyle(.black)
                    .frame(width: 28, height: 28).background(BC.coral, in: Circle())
                Text("\(san) isn't it").font(.system(size: 17, weight: .bold)).foregroundStyle(BC.coral).lineLimit(1)
                Spacer()
            }
            Text(text).font(.system(size: 14)).foregroundStyle(Color(hex: 0xD2D2D6)).lineLimit(3).padding(.top, 8)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Button("Try again") { startRetry(d, i) }.buttonStyle(PillButton(filled: true))
                Button("Show best") { playBest(d, i) }.buttonStyle(PillButton())
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Move strip

    private func moveStrip(_ d: GameReviewData) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 4) {
                    ForEach(0..<d.plies, id: \.self) { i in
                        stripChip(d, i).id(i + 1)
                    }
                }
                .padding(.horizontal, BC.side)
            }
            .scrollIndicators(.hidden)
            .onAppear { proxy.scrollTo(max(1, idx), anchor: .center) }
            .onChange(of: idx) { _, v in
                withAnimation(BC.curve(0.3)) { proxy.scrollTo(max(1, v), anchor: .center) }
            }
        }
    }

    private func stripChip(_ d: GameReviewData, _ i: Int) -> some View {
        let on = idx == i + 1
        let c = d.cls(i)
        let marked = c.map { $0.isSlip || $0 == .brilliant || $0 == .great } ?? false
        return Button { go(i + 1) } label: {
            HStack(spacing: 3) {
                if marked, let c { Text(c.symbol).font(.system(size: 11, weight: .heavy)) }
                Text(d.stripLabels[i]).font(.system(size: 14, weight: on ? .bold : .medium))
            }
            .foregroundStyle(on ? .black : (marked ? c!.colour : BC.ink))
            .padding(.horizontal, 9).frame(height: 32)
            .background(on ? (marked ? c!.colour : BC.ink) : BC.card, in: Capsule())
            .overlay(Capsule().stroke(on ? .clear : BC.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Navigation

    private func startReview(at k: Int) {
        guard let d = data, d.ready else { return }
        board.flipped = d.userColor == .black
        withAnimation(BC.curve(0.3)) { reviewing = true }
        idx = -1
        go(max(0, min(d.plies, k)), keepFocus: focus != nil)
    }

    private func exitReview() {
        line.clear()
        retryTask?.cancel()
        board.userColor = nil
        board.onMove = nil
        panel = .move
        focus = nil
        Task { await EngineService.shared.stop(owner: Self.owner) }
        withAnimation(BC.curve(0.3)) { reviewing = false }
    }

    private func go(_ k: Int, keepFocus: Bool = false) {
        guard let d = data, k >= 0, k <= d.plies else { return }
        line.clear()
        retryTask?.cancel()
        let step = abs(k - idx) == 1
        idx = k
        panel = .move
        if !keepFocus { focus = nil }
        show(d, animated: step)
        if k > 0 { Feel.move(san: d.sans[k - 1]) }
    }

    private func backToMove() {
        guard let d = data else { return }
        line.clear()
        retryTask?.cancel()
        panel = .move
        show(d, animated: false)
    }

    /// Put position idx on the board with the mark badge and, when the move wasn't best, the best move's arrow.
    private func show(_ d: GameReviewData, animated: Bool) {
        board.userColor = nil
        board.onMove = nil
        board.clearMarks()
        let last = idx > 0 ? d.move(idx - 1) : nil
        board.set(fen: d.fens[idx], lastMove: last, animated: animated)
        guard idx > 0, let c = d.cls(idx - 1), let last else { return }
        board.badge = BoardBadge(square: last.to, cls: c)
        if let b = d.betterMove(idx - 1) {
            board.arrows = [BoardArrow(from: String(b.prefix(2)), to: String(b.dropFirst(2).prefix(2)), colour: BC.best, opacity: 0.85)]
        }
    }

    /// Your next move with this mark, looping round. From the summary it opens the review there.
    private func jump(to c: MoveClass) {
        guard let d = data else { return }
        let hits = d.hits(c)
        guard !hits.isEmpty else { return }
        let k = (cycle[c] ?? 0) % hits.count
        cycle[c] = k + 1
        focus = Focus(kind: .mark(c), pos: k + 1, of: hits.count)
        if reviewing {
            go(hits[k] + 1, keepFocus: true)
        } else {
            Feel.tap()
            startReview(at: hits[k] + 1)
        }
    }

    private func nextKeyMoment() {
        guard let d = data, !d.keyPlies.isEmpty else { return }
        let n = d.keyPlies.firstIndex { $0 + 1 > idx } ?? 0
        focus = Focus(kind: .key, pos: n + 1, of: d.keyPlies.count)
        go(d.keyPlies[n] + 1, keepFocus: true)
    }

    // MARK: Lines

    private func playBest(_ d: GameReviewData, _ i: Int) {
        guard let pv = d.review?.bestLines[safe: i], !pv.isEmpty else { return }
        retryTask?.cancel()
        board.userColor = nil
        board.onMove = nil
        panel = .best
        line.play(pv, from: d.fens[i], on: board, colour: BC.best)
    }

    private func playWhy(_ d: GameReviewData, _ i: Int) {
        guard let after = d.review?.bestLines[safe: i + 1] else { return }
        panel = .why
        line.play([d.ucis[i]] + after, from: d.fens[i], on: board, colour: d.cls(i)?.colour ?? BC.mint, limit: 11)
    }

    // MARK: Retry

    private func startRetry(_ d: GameReviewData, _ i: Int) {
        line.clear()
        retryTask?.cancel()
        panel = .retry(.waiting)
        board.clearMarks()
        board.set(fen: d.fens[i], lastMove: i > 0 ? d.move(i - 1) : nil, animated: true)
        board.userColor = d.movers[i]
        board.onMove = { from, to, promo in attempt(d, i, from: from, to: to, promo: promo) }
        Feel.next()
    }

    private func attempt(_ d: GameReviewData, _ i: Int, from: String, to: String, promo: Piece.Kind?) {
        guard let p = Chess.move(from: from, to: to, promotion: promo, on: d.fens[i]) else { return }
        board.userColor = nil
        board.set(fen: p.fenAfter, lastMove: MovePair(from: from, to: to))
        Feel.move(san: p.san)
        let mover = d.movers[i]
        if p.uci == d.ucis[i] {
            judged(false, p, text: "That's the move from the game. Look for something that keeps more.")
            return
        }
        if p.uci == d.review?.best[safe: i] {
            judged(true, p, text: "That's Stockfish's move. It keeps the eval at \(d.evalText(at: i)) instead of \(d.evalText(at: i + 1)).")
            return
        }
        if case .checkmate = Chess.outcome(p.fenAfter) {
            judged(true, p, text: "Checkmate. Nothing beats that.")
            return
        }
        panel = .retry(.checking(p.san))
        let before = d.eval(at: i)
        let winBefore = Eval.win(cp: before.cp, mate: before.mate, for: mover) / 100
        retryTask = Task { @MainActor in
            let lines = await EngineService.shared.analyse(fen: p.fenAfter, depth: 14, owner: Self.owner)
            guard !Task.isCancelled, case .retry(.checking) = panel else { return }
            let after = Eval.points(lines.first, for: mover)
            let loss = max(0, winBefore - after)
            if lines.isEmpty {
                judged(false, p, text: "Stockfish couldn't check that one. Try again.")
            } else if loss < 0.05 {
                judged(true, p, text: "Stockfish agrees: it keeps the position at \(Eval.text(cp: lines.first?.cp, mate: lines.first?.mate)).")
            } else {
                let best = d.review?.best[safe: i].flatMap { Chess.play($0, on: d.fens[i])?.san }
                judged(false, p, text: "It gives away \(Int((loss * 100).rounded()))% of your chances."
                       + (best.map { " Stockfish plays \($0)." } ?? ""))
            }
        }
    }

    private func judged(_ right: Bool, _ p: Ply, text: String) {
        board.tints = [p.to: right ? .right : .wrong]
        if right { Feel.right() } else { Feel.wrong() }
        panel = .retry(right ? .solved(p.san, text) : .wrong(p.san, text))
    }
}

// MARK: - Eval graph

/// White's share across the game; marks as dots; tap or drag to pick a move.
private struct ReviewEvalGraph: View {
    let data: GameReviewData
    var cursor: Int?
    var height: CGFloat = 84
    var onScrub: (Int) -> Void
    var onCommit: (Int) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let n = max(1, data.plies)
            let r = data.review
            Canvas { ctx, _ in
                let bg = Path(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerRadius: 10)
                ctx.fill(bg, with: .color(Color(hex: 0x3A3936)))
                ctx.clip(to: bg)
                func y(_ k: Int) -> CGFloat {
                    let e = data.eval(at: k)
                    return h * (1 - Eval.whiteShare(cp: e.cp, mate: e.mate))
                }
                var area = Path()
                area.move(to: CGPoint(x: 0, y: h))
                if r != nil {
                    for k in 0...n { area.addLine(to: CGPoint(x: w * CGFloat(k) / CGFloat(n), y: y(k))) }
                } else {
                    area.addLine(to: CGPoint(x: 0, y: h / 2))
                    area.addLine(to: CGPoint(x: w, y: h / 2))
                }
                area.addLine(to: CGPoint(x: w, y: h))
                area.closeSubpath()
                ctx.fill(area, with: .color(Color(hex: 0xF0F0F0)))
                var mid = Path()
                mid.move(to: CGPoint(x: 0, y: h / 2))
                mid.addLine(to: CGPoint(x: w, y: h / 2))
                ctx.stroke(mid, with: .color(Color.gray.opacity(0.45)), lineWidth: 1)
                if let r {
                    for (i, c) in r.classes.prefix(n).enumerated() where c == .brilliant || c == .great || c.isError {
                        let p = CGPoint(x: w * CGFloat(i + 1) / CGFloat(n), y: y(i + 1))
                        let s: CGFloat = data.movers[i] == data.userColor ? 8 : 6
                        let dot = Path(ellipseIn: CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s))
                        ctx.fill(dot, with: .color(c.colour))
                        ctx.stroke(dot, with: .color(.black.opacity(0.35)), lineWidth: 1)
                    }
                }
                if let k = cursor {
                    let x = w * CGFloat(k) / CGFloat(n)
                    ctx.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: h)), with: .color(BC.mint))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let k = index(v.location.x, w: w, n: n)
                        if k != cursor { Feel.tick(); onScrub(k) }
                    }
                    .onEnded { v in onCommit(index(v.location.x, w: w, n: n)) }
            )
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Evaluation graph. Tap to jump to a move.")
    }

    private func index(_ x: CGFloat, w: CGFloat, n: Int) -> Int {
        max(0, min(n, Int((x / max(1, w) * CGFloat(n)).rounded())))
    }
}
