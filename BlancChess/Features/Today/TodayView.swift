import SwiftUI

/// Home, laid out like Blanc Notes' Home: you, three ring pills, today's card with one white button, three tiles.
struct TodayView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var progress: ProgressStore
    @EnvironmentObject var store: GameStore
    @State private var daily: [Puzzle] = []
    @State private var lead: Lead?
    @State private var leadKey: LeadKey?
    @State private var leadAt = Date.distantPast
    @Environment(\.tabVisible) private var tabVisible

    /// The first move today's session asks for, shown on the card.
    struct Lead { let fen: String; let flipped: Bool; let arrow: MovePair?; let title: String; let last: [String]; let history: [String] }

    private var linked: Bool { progress.settings.linked }

    var body: some View {
        let plan = SessionPlan(app: app, progress: progress, daily: daily)
        GeometryReader { geo in
            // Small phones (iPhone SE): tighter spacing and a smaller board so everything fits above the dock.
            // It still scrolls if anything ever doesn't fit.
            let compact = geo.size.height < 700
            ScrollView {
                VStack(alignment: .leading, spacing: compact ? 14 : 24) {
                    greetingRow.arrive(0)
                    pills.arrive(1)
                    heroCard(plan, board: boardSize(geo.size)).arrive(2)
                    tiles(plan).arrive(3)
                }
                .padding(.horizontal, BC.side)
                .padding(.top, compact ? 8 : 22)
                .padding(.bottom, BC.dockClearance + 12)
                .readableColumn()
            }
            .scrollIndicators(.hidden)
            .topFade()
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Spotlight(colour: BC.amber))
        .task(id: visible ? store.revision : -1) { if visible { await refresh() } }
        .task(id: LeadKey(version: progress.version, reps: app.repertoires.map(\.id), visible: visible)) { await updateLead() }
    }

    /// Today is on screen: its tab is in front with nothing pushed over it.
    private var visible: Bool { tabVisible && (app.paths[.today] ?? []).isEmpty }

    private struct LeadKey: Equatable { let version: Int; let reps: [String]; let visible: Bool }

    /// The lead builds a whole practice session: only while Today shows, and not on every answer
    /// (progress changes many times a minute while you practise).
    private func updateLead() async {
        guard visible else { return }
        let key = LeadKey(version: progress.version, reps: app.repertoires.map(\.id), visible: true)
        // Due dates pass with time too: coming back to Today after a while works it out again.
        guard key != leadKey || Date().timeIntervalSince(leadAt) > 60 else { return }
        if leadKey != nil {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
        }
        leadKey = key
        leadAt = Date()
        lead = Self.lead(app)
    }

    /// Today's positions are worked out after the first frame, cached on the review revision.
    private func refresh() async {
        await Task.yield()
        guard linked else { return }
        let snap = await TrainingCache.shared.snapshot(store, app.repertoires)
        daily = DailySet.puzzles(snap, progress)
    }

    // MARK: You

    private var name: String? {
        let n = progress.settings.name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? store.profileName : n
    }

    private var greetingRow: some View {
        HStack(spacing: 12) {
            Button { Feel.tick(); app.open(.settings) } label: {
                AvatarTile(image: store.avatar, size: 44)
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("You and settings")
            VStack(alignment: .leading, spacing: 1) {
                Text(Date().formatted(.dateTime.weekday(.wide)))
                    .font(.system(size: 13)).foregroundStyle(BC.mute)
                Text(DayText.greeting(name: name))
                    .font(.bcGreeting).tracking(-0.4).foregroundStyle(BC.ink)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 8)
            CircleButton(systemImage: "gearshape", label: "Settings") { app.open(.settings) }
        }
    }

    // MARK: Pills

    private var pills: some View {
        let reps = app.repertoires
        let coverage = reps.isEmpty ? 0 : reps.map { progress.coverage($0) }.reduce(0, +) / Double(reps.count)
        let streak = progress.streak
        let r = rating
        return HStack(alignment: .top, spacing: 10) {
            RingPill(icon: "flame", value: "\(streak)", label: "Day streak", colour: BC.amber,
                     progress: streak == 0 ? 0 : Double((streak - 1) % 7 + 1) / 7)
            Button { Feel.tick(); app.tab = .insights } label: {
                RingPill(icon: "star", value: r.map { "\($0.value)" } ?? "–", label: r?.label ?? "Rating",
                         colour: .white, progress: r.map { Double($0.value % 100) / 100 } ?? 0)
            }
            .buttonStyle(PressStyle())
            Button { Feel.tick(); app.tab = .openings } label: {
                RingPill(icon: "book.closed", value: "\(Int((coverage * 100).rounded()))%", label: "Openings",
                         colour: BC.blue, progress: coverage)
            }
            .buttonStyle(PressStyle())
        }
    }

    /// Your rating in the speed you played last.
    private var rating: (value: Int, label: String)? {
        guard linked, let last = store.games.max(by: { $0.endTime < $1.endTime }) else { return nil }
        let tc = last.timeClass
        let s: ChessCom.Stats.Mode? = tc == "rapid" ? store.stats?.chess_rapid : tc == "blitz" ? store.stats?.chess_blitz
            : tc == "bullet" ? store.stats?.chess_bullet : nil
        let v = s?.last?.rating ?? last.userRating
        return (v, tc.capitalized)
    }

    // MARK: Today's card

    private func heroCard(_ plan: SessionPlan, board boardSize: CGFloat) -> some View {
        let next = lead
        return CardBox(padding: 12, radius: 26) {
            VStack(alignment: .leading, spacing: 0) {
                Button { start(plan) } label: {
                    MiniBoard(fen: next?.fen ?? Chess.startFEN, size: boardSize, flipped: next?.flipped ?? false,
                              highlight: next?.last ?? [], radius: 14)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel("Start today's practice from this position")
                HStack(spacing: 8) {
                    Text(plan.hasWork ? (next?.title ?? "Today's practice") : "All done today")
                        .font(.bcCardTitle).foregroundStyle(BC.ink).lineLimit(1).minimumScaleFactor(0.8)
                    if plan.hasWork { Tag(text: "≈ \(plan.minutes) min", colour: BC.amber) }
                    Spacer(minLength: 8)
                    Button {
                        Feel.tick()
                        app.open(.board(BoardStart(fen: Chess.startFEN, history: next?.history ?? [],
                                                   title: next?.title ?? "Analysis", flipped: next?.flipped ?? false)))
                    } label: {
                        Label("Analyse", systemImage: "cpu")
                            .font(.system(size: 13, weight: .bold)).foregroundStyle(BC.ink)
                            .padding(.horizontal, 12).frame(height: 32)
                            .background(BC.raised, in: Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
                    }
                    .buttonStyle(PressStyle())
                }
                .padding(.horizontal, 4)
                .padding(.top, 12)
                BlockButton(title: plan.hasWork ? "Start today's practice" : "15-minute session", systemImage: "play.fill") {
                    start(plan)
                }
                .padding(.top, 12)
            }
        }
    }

    /// Square, and small enough that Home fits on one screen above the dock. `space` is the window inside
    /// its safe area (the clock and home indicator), so Split View and Stage Manager size it right too.
    private func boardSize(_ space: CGSize) -> CGFloat {
        let column = min(space.width, BC.readable)
        return max(space.height < 700 ? 136 : 170, min(column - 2 * BC.side - 24, space.height - 554))
    }

    private func start(_ plan: SessionPlan) {
        if plan.openingWork { app.open(.practice(PracticeRequest(repID: nil, mode: .mixed, title: "Today"))) }
        else if plan.positions > 0 { solveDaily() }
        else { app.open(.practice(PracticeRequest(repID: nil, mode: .session, title: "Session"))) }
    }

    /// Builds today's session the way Start will, and takes its first move of yours.
    static func lead(_ app: AppModel) -> Lead? {
        let session = PracticeSession(request: PracticeRequest(repID: nil, mode: .mixed, title: "Today"),
                                      reps: app.repertoires, progress: app.progress)
        guard let line = session.lines.first else { return nil }
        // The first move that's actually new or due, not the known moves that lead up to it.
        let yours = line.steps.indices.filter { $0 >= line.start && line.steps[$0].mover == line.rep.color }
        let i = yours.first { line.kinds[$0] != nil && line.kinds[$0] != .known } ?? yours.first ?? line.start
        guard line.steps.indices.contains(i) else { return nil }
        let n = line.steps[i]
        let prev = i > 0 ? [line.steps[i - 1].from, line.steps[i - 1].to] : []
        return Lead(fen: n.fenBefore, flipped: line.rep.color == .black, arrow: MovePair(from: n.from, to: n.to), title: line.title,
                    last: prev, history: line.steps.prefix(i).map(\.uci))
    }

    // MARK: Tiles

    private func tiles(_ plan: SessionPlan) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                Feel.tick()
                app.open(.practice(PracticeRequest(repID: nil, mode: .learn, title: "New moves")))
            } label: {
                QuestTile(icon: "sparkles", title: "New moves",
                          line: plan.new > 0 ? "\(plan.new) to learn" : "\(progress.newLearnedToday) today · more",
                          colour: BC.blue)
            }
            .buttonStyle(PressStyle())
            Button {
                Feel.tick()
                app.open(.practice(plan.due > 0 ? PracticeRequest(repID: nil, mode: .review, title: "Reviews")
                                                 : PracticeRequest(repID: nil, mode: .revise, title: "Revise")))
            } label: {
                QuestTile(icon: plan.due > 0 ? "arrow.triangle.2.circlepath" : "shuffle", title: plan.due > 0 ? "Reviews" : "Revise",
                          line: plan.due > 0 ? "\(plan.due) due" : "Test yourself",
                          colour: BC.blue)
            }
            .buttonStyle(PressStyle())
            Button {
                Feel.tick()
                if !linked { app.open(.link) }
                else if plan.positions > 0 { solveDaily() }
                else { app.open(.puzzles(PuzzleSet(source: .daily, title: "Your positions"))) }
            } label: {
                QuestTile(icon: linked ? "scope" : "link", title: linked ? "Your games" : "Link chess.com",
                          line: !linked ? "See your slips" : plan.positions > 0 ? "\(plan.positions) to fix" : "Done",
                          done: linked && plan.positions == 0 && !daily.isEmpty, colour: BC.coral)
            }
            .buttonStyle(PressStyle())
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Today's positions, straight into solving (no list first).
    private func solveDaily() {
        let set = PuzzleSet(source: .daily, title: "Your positions")
        PuzzleLaunch.startSolving(set)
        app.open(.puzzles(set))
    }
}

/// A board seen up close inside a card: cropped round the move it's about, fading into the dark at the top.
struct BoardStage: View {
    let fen: String
    var flipped = false
    var arrow: MovePair? = nil

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let q = w / 8
            // Centre the crop on the move (in screen rows from the top), clamped to the board.
            let row: CGFloat = {
                guard let a = arrow else { return 5.5 }
                func r(_ sq: String) -> CGFloat {
                    let rank = CGFloat(Int(String(sq.last ?? "1")) ?? 1)
                    return flipped ? rank - 0.5 : 8.5 - rank
                }
                return (r(a.from) + r(a.to)) / 2
            }()
            let top = min(max(0, row * q - geo.size.height / 2), w - geo.size.height)
            ZStack(alignment: .top) {
                MiniBoard(fen: fen, size: w, flipped: flipped, arrow: arrow, radius: 0)
                    .offset(y: -top)
                LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0),
                                       .init(color: .black.opacity(0), location: 0.3)],
                               startPoint: .top, endPoint: .bottom)
            }
            .frame(width: w, height: geo.size.height, alignment: .top)
            .clipped()
        }
        .accessibilityHidden(true)
    }
}

/// What today's session holds and roughly how long it takes.
@MainActor
struct SessionPlan {
    let due: Int
    let new: Int
    let positions: Int
    let nextReview: Date?

    init(app: AppModel, progress: ProgressStore, daily: [Puzzle]) {
        // Cached in ProgressStore: Today re-renders every second while a review runs.
        let (due, fresh, next) = progress.planCounts(app.repertoires)
        self.due = due
        self.new = min(fresh, max(0, progress.settings.newMovesPerDay - progress.newLearnedToday))
        let tried = DailySet.triedToday
        self.positions = daily.filter { !tried.contains($0.id) }.count
        self.nextReview = next
    }

    var openingWork: Bool { due + new > 0 }
    var hasWork: Bool { openingWork || positions > 0 }

    /// A rough guess: a due move ~10 s, a new one ~40 s, a position ~50 s.
    var minutes: Int { max(1, Int((Double(due) * 10 + Double(new) * 40 + Double(positions) * 50) / 60 + 0.5)) }
}
