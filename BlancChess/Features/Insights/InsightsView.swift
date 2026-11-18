import SwiftUI
import Charts

/// Where am I going wrong: your ratings, your leaks, when and how you slip, your openings.
struct InsightsView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var progress: ProgressStore
    @EnvironmentObject var store: GameStore

    @State private var data: InsightsData?
    @State private var ratingClass: String? = nil
    @State private var allOpenings = false
    @State private var cache = InsightsCache()
    @State private var dataRevision = -1
    @Environment(\.tabVisible) private var tabVisible

    private var linked: Bool { progress.settings.linked }

    var body: some View {
        cache.refresh(store)
        let reviewed = cache.reviewedCount
        return content(reviewed: reviewed)
    }

    private func content(reviewed: Int) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                TabHeader(title: "Insights")
                    .arrive(0)
                if !linked {
                    EmptyCard(title: "Link chess.com", message: "Insights come from your own games: where you lose points, when, and in which openings.",
                              actionTitle: "Link your account") { app.open(.link) }
                        .arrive(1)
                } else {
                    profile.arrive(1)
                    WeeklyCard().arrive(1)
                    if reviewed == 0 {
                        notReviewed.arrive(2)
                    } else if let d = data {
                        blunderCheckCard.arrive(2)
                        weaknesses(d).arrive(2)
                        phases(d).arrive(3)
                        accuracy(d).arrive(4)
                        openings(d).arrive(5)
                    }
                }
                endgames.arrive(6)
            }
            .padding(.horizontal, BC.side)
            .padding(.top, BC.top)
            .padding(.bottom, BC.dockClearance + 12)
            .readableColumn()
        }
        .scrollIndicators(.hidden)
        .topFade()
        .background(Spotlight(colour: BC.coral))
        // Worked out while Insights is in front (again on coming back if the games changed meanwhile).
        .task(id: tabVisible ? store.revision : -1) {
            guard tabVisible, dataRevision != store.revision else { return }
            let revision = store.revision
            let snap = await TrainingCache.shared.snapshot(store, app.repertoires)
            cache.refresh(store)
            let d = InsightsData(snapshot: snap, reviewed: cache.reviewed)
            dataRevision = revision
            withAnimation(BC.curve(0.3)) { data = d }
        }
    }

    // MARK: Profile

    private var profile: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(["rapid", "blitz", "bullet"], id: \.self) { tc in ratingCard(tc) }
            }
            if let tc = ratingClass {
                ratingChart(tc).transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(BC.curve(0.35), value: ratingClass)
    }

    private func current(_ tc: String) -> Int? {
        let s: ChessCom.Stats.Mode? = tc == "rapid" ? store.stats?.chess_rapid : tc == "blitz" ? store.stats?.chess_blitz : store.stats?.chess_bullet
        return s?.last?.rating ?? cache.history(tc).last?.1
    }

    private func ratingCard(_ tc: String) -> some View {
        let history = cache.history(tc)
        let change = history.count > 1 ? (current(tc) ?? history.last!.1) - history.first!.1 : nil
        let on = ratingClass == tc
        return Button {
            Feel.tick()
            ratingClass = on || history.count < 2 ? nil : tc
        } label: {
            StatCard(label: tc.capitalized, value: current(tc).map(String.init) ?? "–",
                     context: change.map { $0 == 0 ? "±0" : $0 > 0 ? "+\($0)" : "−\(-$0)" } ?? (history.isEmpty ? "No games" : "1 game"),
                     colour: BC.ink)
                .overlay(alignment: .bottomTrailing) {
                    if let change, change != 0 {
                        Image(systemName: change > 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.system(size: 11, weight: .bold)).foregroundStyle(change > 0 ? BC.mint : BC.coral)
                            .padding(14)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: BC.rRow, style: .continuous).stroke(on ? BC.ink.opacity(0.6) : .clear, lineWidth: 1.5))
        }
        .buttonStyle(PressStyle())
        .accessibilityHint(history.count > 1 ? "Shows the rating chart" : "")
    }

    private func ratingChart(_ tc: String) -> some View {
        let h = cache.history(tc)
        let lo = (h.map(\.1).min() ?? 0), hi = (h.map(\.1).max() ?? 0)
        return CardBox(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    LabelText("\(tc.capitalized) rating")
                    Spacer()
                    Text("\(lo) – \(hi)").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(BC.mute)
                }
                Chart {
                    ForEach(Array(h.enumerated()), id: \.offset) { _, p in
                        AreaMark(x: .value("Date", p.0), yStart: .value("Base", lo - 10), yEnd: .value("Rating", p.1))
                            .foregroundStyle(LinearGradient(colors: [BC.ink.opacity(0.16), .clear], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Date", p.0), y: .value("Rating", p.1))
                            .foregroundStyle(BC.ink)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                            .interpolationMethod(.monotone)
                    }
                    if let best = h.max(by: { $0.1 < $1.1 }) {
                        PointMark(x: .value("Date", best.0), y: .value("Rating", best.1)).foregroundStyle(BC.amber).symbolSize(40)
                    }
                }
                .chartYScale(domain: (lo - 10)...(hi + 10))
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.day().month(.abbreviated)).foregroundStyle(BC.mute) } }
                .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(BC.line)
                    AxisValueLabel().foregroundStyle(BC.mute)
                } }
                .frame(height: 150)
            }
        }
    }

    // MARK: Not reviewed

    @ViewBuilder
    private var notReviewed: some View {
        if store.games.isEmpty {
            EmptyCard(title: store.importing ? "Bringing in your games" : "No games yet",
                      message: store.importing ? (store.status ?? "Fetching from chess.com…") : "No games in the last \(AppSettings.historyName(progress.settings.historyMonths)). Sync to check again.",
                      actionTitle: store.importing ? nil : "Sync games") {
                let s = progress.settings
                Task { await store.sync(user: s.chessComUser, months: s.historyMonths, autoReview: s.autoReview) }
            }
        } else {
            ReviewStatusReader(status: store.live) { live in
                if live.pending > 0 {
                    CardBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Reviewing your games").font(.bcCardTitle).foregroundStyle(BC.ink)
                            Text("Stockfish is going through them one by one. Your insights appear as soon as the first ones are done.")
                                .font(.bcBody).foregroundStyle(BC.mute).fixedSize(horizontal: false, vertical: true)
                            ProgressBar(value: live.progress, colour: BC.violet, height: 6).padding(.top, 4)
                            Text("\(live.pending) in the queue").font(.bcCaption).foregroundStyle(BC.mute)
                        }
                    }
                } else {
                    EmptyCard(title: "Review your games", message: "\(cache.unreviewedCount) games are waiting. Stockfish reviews them in the background.",
                              actionTitle: "Review my games") {
                        store.enqueueReviews(store.unreviewed.prefix(40).map(\.id))
                    }
                }
            }
        }
    }

    // MARK: Blunder check

    /// The daily drill for middlegame blunders: see what your move allowed, then find a safe one.
    private var blunderCheckCard: some View {
        Button { Feel.tick(); app.open(.blunderCheck) } label: {
            CardBox {
                HStack(spacing: 14) {
                    IconTile(systemImage: "shield.lefthalf.filled", colour: BC.coral, size: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Blunder check").font(.bcCardTitle).foregroundStyle(BC.ink)
                        Text("10 of your slips: what did it allow, what was safe?")
                            .font(.bcCaption).foregroundStyle(BC.mute).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "play.fill").font(.system(size: 14, weight: .bold)).foregroundStyle(.black)
                        .frame(width: 40, height: 40).background(Color.white, in: Circle())
                }
            }
        }
        .buttonStyle(PressStyle())
    }

    // MARK: Weaknesses

    @ViewBuilder
    private func weaknesses(_ d: InsightsData) -> some View {
        SectionBox(title: "Where you lose points · \(cache.reviewedCount) games") {
            if d.weaknesses.isEmpty {
                CardBox { Text("Nothing costs you points twice yet. Review more games for a clearer picture.").font(.bcBody).foregroundStyle(BC.mute) }
            } else {
                let worst = max(0.0001, d.weaknesses.first?.pointsLost ?? 1)
                RowGroup {
                    ForEach(d.weaknesses) { w in
                        Button { app.open(.weakness(w.kind.rawValue)) } label: {
                            HStack(spacing: 12) {
                                IconTile(systemImage: w.icon, colour: BC.coral)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(w.title).font(.bcRowTitle).foregroundStyle(BC.ink).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                    HStack(spacing: 8) {
                                        Text(w.summary).font(.bcCaption).foregroundStyle(BC.mute).lineLimit(1).layoutPriority(1)
                                        ProgressBar(value: w.pointsLost / worst, colour: BC.coral.opacity(0.85), height: 5)
                                    }
                                }
                                Image(systemName: "chevron.forward").font(.system(size: 13, weight: .semibold)).foregroundStyle(BC.mute)
                            }
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: Phases

    private func phases(_ d: InsightsData) -> some View {
        let top = max(0.01, d.phases.map(\.1).max() ?? 0)
        return SectionBox(title: "By phase") {
            CardBox(padding: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(d.phases, id: \.0) { phase, rate in
                        Button {
                            app.open(.puzzles(PuzzleSet(source: .mistakes(phase.rawValue), title: "\(phase.rawValue) slips")))
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(phase.rawValue).font(.bcBodyStrong).foregroundStyle(BC.ink)
                                    Spacer()
                                    Text(String(format: "%.1f", rate)).font(.system(size: 14, weight: .bold).monospacedDigit())
                                        .foregroundStyle(rate == top && rate > 0 ? BC.coral : BC.ink)
                                    + Text(" per game").font(.bcCaption).foregroundStyle(BC.mute)
                                    Image(systemName: "chevron.forward").font(.system(size: 11, weight: .semibold)).foregroundStyle(BC.faint)
                                }
                                ProgressBar(value: rate / top, colour: rate == top ? BC.coral : BC.coral.opacity(0.45))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: Accuracy

    @ViewBuilder
    private func accuracy(_ d: InsightsData) -> some View {
        if !d.trend.isEmpty {
            SectionBox(title: "Accuracy") {
                CardBox(padding: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(String(format: "%.1f", d.average)).font(.bcStat).foregroundStyle(BC.ink)
                            Text("average").font(.bcCaption).foregroundStyle(BC.mute)
                            Spacer()
                        }
                        Chart {
                            RuleMark(y: .value("Average", d.average))
                                .foregroundStyle(BC.mute.opacity(0.5))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            ForEach(Array(d.trend.enumerated()), id: \.offset) { i, p in
                                LineMark(x: .value("Game", i), y: .value("Accuracy", p.1))
                                    .foregroundStyle(BC.ink.opacity(0.55))
                                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                                    .interpolationMethod(.monotone)
                                PointMark(x: .value("Game", i), y: .value("Accuracy", p.1))
                                    .foregroundStyle(d.best?.id == d.trendIDs[i] ? BC.amber : BC.ink)
                                    .symbolSize(d.best?.id == d.trendIDs[i] ? 60 : 16)
                            }
                        }
                        .chartXAxis(.hidden)
                        .chartYScale(domain: max(0, (d.trend.map(\.1).min() ?? 0) - 5)...min(100, (d.trend.map(\.1).max() ?? 100) + 5))
                        .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                            AxisGridLine().foregroundStyle(BC.line)
                            AxisValueLabel().foregroundStyle(BC.mute)
                        } }
                        .frame(height: 130)
                        if let best = d.best {
                            Button { app.go(.games, .game(best.id)) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "star.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(BC.amber)
                                        .frame(width: 32, height: 32).background(BC.amber.opacity(0.14), in: Circle())
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text("Your best: \(String(format: "%.1f", best.userAccuracy ?? 0))")
                                            .font(.bcBodyStrong).foregroundStyle(BC.ink)
                                        Text("vs \(best.opponent) · \(best.endTime.formatted(.dateTime.day().month()))")
                                            .font(.bcCaption).foregroundStyle(BC.mute).lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.forward").font(.system(size: 13, weight: .semibold)).foregroundStyle(BC.mute)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: Openings

    @ViewBuilder
    private func openings(_ d: InsightsData) -> some View {
        if !d.openings.isEmpty {
            SectionBox(title: "Your openings") {
                RowGroup {
                    ForEach(allOpenings ? d.openings : Array(d.openings.prefix(5))) { o in
                        Button { openOpening(o, d) } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                HStack(spacing: 8) {
                                    Text(o.name).font(.bcRowTitle).foregroundStyle(BC.ink).lineLimit(1).minimumScaleFactor(0.8)
                                    Spacer(minLength: 4)
                                    Text("\(Int((o.winRate * 100).rounded()))% won").font(.system(size: 13, weight: .semibold).monospacedDigit())
                                        .foregroundStyle(o.winRate >= 0.5 ? BC.mint : BC.ink)
                                    Image(systemName: "chevron.forward").font(.system(size: 13, weight: .semibold)).foregroundStyle(BC.mute)
                                }
                                WDLBar(win: o.wins, draw: o.draws, loss: o.games - o.wins - o.draws)
                                HStack(spacing: 10) {
                                    Text("\(o.games) game\(o.games == 1 ? "" : "s")").foregroundStyle(BC.ink)
                                    Text("\(o.wins) won").foregroundStyle(BC.mint)
                                    Text("\(o.draws) drawn").foregroundStyle(BC.mute)
                                    Text("\(o.games - o.wins - o.draws) lost").foregroundStyle(BC.coral)
                                    Spacer(minLength: 0)
                                    Text(o.color == .white ? "White" : "Black").foregroundStyle(BC.mute)
                                }
                                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                                .lineLimit(1).minimumScaleFactor(0.8)
                            }
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if d.openings.count > 5 {
                        Button {
                            Feel.tick()
                            withAnimation(BC.curve(0.3)) { allOpenings.toggle() }
                        } label: {
                            Text(allOpenings ? "Show fewer" : "Show all \(d.openings.count)")
                                .font(.system(size: 15, weight: .semibold)).foregroundStyle(BC.mute)
                                .frame(maxWidth: .infinity, minHeight: 46)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// The opening in your repertoire, at the position your games reach; otherwise the Openings tab.
    private func openOpening(_ o: GameStore.OpeningStat, _ d: InsightsData) {
        Feel.tick()
        if let spot = d.spots[o.id], app.repertoire(spot.rep)?.node(spot.node) != nil {
            app.open(.explore(rep: spot.rep, node: spot.node))
        } else {
            app.go(.openings)
        }
    }

    // MARK: Endgames

    /// Always here, linked or not: the six endings every club player should know.
    private var endgames: some View {
        RowGroup {
            Button { app.open(.endgames) } label: {
                Row(title: "Endgame drills", subtitle: "\(EndgameDrill.all.count) core endings") {
                    IconTile(systemImage: "flag.checkered", colour: BC.coral)
                }
            }
            .buttonStyle(.plain)
        }
    }
}

/// Win, draw, loss as one thin bar.
struct WDLBar: View {
    let win: Int, draw: Int, loss: Int
    var body: some View {
        let total = Double(max(1, win + draw + loss))
        GeometryReader { geo in
            HStack(spacing: 2) {
                if win > 0 { Rectangle().fill(BC.mint).frame(width: geo.size.width * Double(win) / total) }
                if draw > 0 { Rectangle().fill(BC.faint).frame(width: geo.size.width * Double(draw) / total) }
                if loss > 0 { Rectangle().fill(BC.coral).frame(maxWidth: .infinity) }
            }
        }
        .frame(height: 6)
        .clipShape(Capsule())
        .accessibilityLabel("\(win) won, \(draw) drawn, \(loss) lost")
    }
}

/// Everything Insights shows, from the training snapshot (worked out off the main thread once per review revision).
struct InsightsData {
    let weaknesses: [Weakness]
    let phases: [(Phase, Double)]
    let trend: [(Date, Double)]
    let trendIDs: [String]
    let average: Double
    let best: GameRecord?
    let openings: [GameStore.OpeningStat]
    let spots: [String: TrainingSnapshot.OpeningSpot]

    init(snapshot s: TrainingSnapshot, reviewed: [GameRecord]) {
        weaknesses = s.weaknesses
        phases = s.phases
        let games = reviewed.filter { $0.userAccuracy != nil }.sorted { $0.endTime < $1.endTime }
        trend = games.map { ($0.endTime, $0.userAccuracy!) }
        trendIDs = games.map(\.id)
        average = trend.isEmpty ? 0 : trend.map(\.1).reduce(0, +) / Double(trend.count)
        best = games.max { ($0.userAccuracy ?? 0) < ($1.userAccuracy ?? 0) }
        openings = s.openings
        spots = s.openingNodes
    }
}

/// The cheap-but-not-free numbers Insights reads on every redraw (reviewed games, rating histories),
/// worked out once per store revision instead of in `body`.
@MainActor
final class InsightsCache {
    private var key: (Int, Int) = (-1, -1)
    private(set) var reviewed: [GameRecord] = []
    private(set) var unreviewedCount = 0
    private var histories: [String: [(Date, Int)]] = [:]

    var reviewedCount: Int { reviewed.count }

    func refresh(_ store: GameStore) {
        guard key != (store.revision, store.games.count) else { return }
        key = (store.revision, store.games.count)
        reviewed = store.reviewed
        unreviewedCount = store.games.count - reviewed.count
        histories = [:]
        for tc in ["rapid", "blitz", "bullet"] { histories[tc] = store.ratingHistory(tc) }
    }

    /// Your rating over time in one speed, oldest first (GameStore.ratingHistory, cached).
    func history(_ timeClass: String) -> [(Date, Int)] { histories[timeClass] ?? [] }
}
