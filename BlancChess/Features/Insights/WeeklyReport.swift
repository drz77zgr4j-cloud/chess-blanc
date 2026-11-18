import SwiftUI
import Charts

/// One week of your chess, worked out from your games and your practice.
struct WeekStats {
    let start: Date
    let end: Date
    var games = 0, wins = 0, draws = 0, losses = 0
    var accuracy: Double?
    var blundersPerGame: Double?
    var hungPerGame: Double?
    var rating: (start: Int, end: Int, timeClass: String)?
    var daysPractised = 0
    var movesLearned = 0
    var best: GameRecord?
    var byDay: [(Date, Double)] = []      // average accuracy per day

    @MainActor
    static func make(_ all: [GameRecord], _ progress: ProgressStore, start: Date, end: Date) -> WeekStats {
        var w = WeekStats(start: start, end: end)
        let games = all.filter { $0.endTime >= start && $0.endTime < end }
        w.games = games.count
        w.wins = games.filter { $0.result == .win }.count
        w.draws = games.filter { $0.result == .draw }.count
        w.losses = w.games - w.wins - w.draws
        let reviewed = games.filter { $0.review?.version == GameReview.currentVersion }
        let accs = reviewed.compactMap(\.userAccuracy)
        if !accs.isEmpty { w.accuracy = accs.reduce(0, +) / Double(accs.count) }
        if !reviewed.isEmpty {
            let n = Double(reviewed.count)
            w.blundersPerGame = Double(reviewed.reduce(0) { $0 + $1.count(.blunder) }) / n
            let hung = reviewed.reduce(0) { acc, g in
                guard let themes = g.review?.themes else { return acc }
                return acc + themes.enumerated().filter { g.moverAt($0.offset) == g.userColor && $0.element == .hungPiece }.count
            }
            w.hungPerGame = Double(hung) / n
        }
        // Rating in the speed you played most this week.
        if let tc = Dictionary(grouping: games, by: \.timeClass).max(by: { $0.value.count < $1.value.count })?.key {
            let list = games.filter { $0.timeClass == tc }.sorted { $0.endTime < $1.endTime }
            if let first = list.first, let last = list.last { w.rating = (first.userRating, last.userRating, tc) }
        }
        w.daysPractised = progress.practisedDays(from: start, to: end)
        w.movesLearned = progress.movesLearned(from: start, to: end)
        w.best = reviewed.max { ($0.userAccuracy ?? 0) < ($1.userAccuracy ?? 0) }
        let cal = Calendar.current
        var days: [Date: [Double]] = [:]
        for g in reviewed {
            guard let a = g.userAccuracy else { continue }
            days[cal.startOfDay(for: g.endTime), default: []].append(a)
        }
        var byDay: [(Date, Double)] = []
        for (d, list) in days { byDay.append((d, list.reduce(0, +) / Double(list.count))) }
        w.byDay = byDay.sorted { $0.0 < $1.0 }
        return w
    }

    /// This week (the last 7 days) and the 7 before.
    @MainActor
    static func pair(_ all: [GameRecord], _ progress: ProgressStore) -> (this: WeekStats, last: WeekStats) {
        let now = Date()
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: now))!
        let prev = cal.date(byAdding: .day, value: -7, to: start)!
        return (make(all, progress, start: start, end: now.addingTimeInterval(60)), make(all, progress, start: prev, end: start))
    }
}

/// `WeekStats.pair`, worked out again only when the games or your practice change (or a minute passes),
/// not on every redraw.
@MainActor
final class WeekCache {
    private struct Key: Equatable { let revision: Int; let games: Int; let progress: Int }
    private var key: Key?
    private var at = Date.distantPast
    private var value: (this: WeekStats, last: WeekStats)?

    func pair(_ store: GameStore, _ progress: ProgressStore) -> (this: WeekStats, last: WeekStats) {
        let k = Key(revision: store.revision, games: store.games.count, progress: progress.version)
        if let value, k == key, Date().timeIntervalSince(at) < 60 { return value }
        let v = WeekStats.pair(store.games, progress)
        key = k
        at = Date()
        value = v
        return v
    }
}

/// "+3.1" in mint when it's better, coral when worse.
private struct Delta: View {
    let now: Double?
    let then: Double?
    var lowerIsBetter = false
    var format = "%.1f"
    var body: some View {
        if let now, let then {
            let d = now - then
            let good = lowerIsBetter ? d < 0 : d > 0
            Text((d >= 0 ? "+" : "−") + String(format: format, abs(d)) + " vs last week")
                .foregroundStyle(abs(d) < 0.05 ? BC.mute : good ? BC.mint : BC.coral)
        } else {
            Text("no data last week").foregroundStyle(BC.faint)
        }
    }
}

/// The Insights card: this week in three numbers.
struct WeeklyCard: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: GameStore
    @EnvironmentObject var progress: ProgressStore
    @State private var week = WeekCache()

    var body: some View {
        let (w, l) = week.pair(store, progress)
        Button { Feel.tick(); app.open(.weeklyReport) } label: {
            CardBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        LabelText("This week", colour: BC.amber)
                        Spacer()
                        Image(systemName: "chevron.forward").font(.system(size: 13, weight: .semibold)).foregroundStyle(BC.mute)
                    }
                    HStack(alignment: .top, spacing: 0) {
                        mini("\(w.games)", "games", w.games > l.games ? BC.mint : BC.ink)
                        mini(w.accuracy.map { String(format: "%.1f", $0) } ?? "–", "accuracy",
                             color(w.accuracy, l.accuracy, lowerIsBetter: false))
                        mini(w.blundersPerGame.map { String(format: "%.1f", $0) } ?? "–", "blunders a game",
                             color(w.blundersPerGame, l.blundersPerGame, lowerIsBetter: true))
                    }
                }
            }
        }
        .buttonStyle(PressStyle())
    }

    private func mini(_ v: String, _ label: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(v).font(.bcStat).foregroundStyle(c).contentTransition(.numericText())
            Text(label).font(.system(size: 12)).foregroundStyle(BC.mute).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func color(_ a: Double?, _ b: Double?, lowerIsBetter: Bool) -> Color {
        guard let a, let b, abs(a - b) >= 0.05 else { return BC.ink }
        return (lowerIsBetter ? a < b : a > b) ? BC.mint : BC.coral
    }
}

/// The full weekly report: every number against last week, your best game, and what to work on next.
struct WeeklyReportView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: GameStore
    @EnvironmentObject var progress: ProgressStore
    @State private var focus: Weakness?
    @State private var week = WeekCache()

    var body: some View {
        let (w, l) = week.pair(store, progress)
        VStack(spacing: 0) {
            NavBar(title: "This week", subtitle: range(w))
            ScrollView {
                VStack(alignment: .leading, spacing: BC.gap) {
                    headline(w, l).arrive(0)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                        tile("Games", "\(w.games)", "\(w.wins) W · \(w.draws) D · \(w.losses) L") { EmptyView() }
                        tile("Rating", w.rating.map { "\($0.end)" } ?? "–", w.rating.map { r in
                            let d = r.end - r.start
                            return "\(d >= 0 ? "+" : "−")\(abs(d)) \(r.timeClass)"
                        } ?? "no games") { EmptyView() }
                        tile("Accuracy", w.accuracy.map { String(format: "%.1f", $0) } ?? "–", nil) {
                            Delta(now: w.accuracy, then: l.accuracy)
                        }
                        tile("Blunders a game", w.blundersPerGame.map { String(format: "%.1f", $0) } ?? "–", nil) {
                            Delta(now: w.blundersPerGame, then: l.blundersPerGame, lowerIsBetter: true)
                        }
                        tile("Pieces hung a game", w.hungPerGame.map { String(format: "%.1f", $0) } ?? "–", nil) {
                            Delta(now: w.hungPerGame, then: l.hungPerGame, lowerIsBetter: true)
                        }
                        tile("Practice", "\(w.daysPractised) of 7", "\(w.movesLearned) opening moves learned") { EmptyView() }
                    }
                    .arrive(1)
                    if w.byDay.count >= 2 { chart(w).arrive(2) }
                    if let b = w.best { bestGame(b).arrive(3) }
                    if let f = focus { focusCard(f).arrive(4) }
                }
                .padding(.horizontal, BC.side)
                .padding(.top, 8)
                .padding(.bottom, 40)
                .readableColumn()
            }
            .scrollIndicators(.hidden)
        }
        .background(Spotlight(colour: BC.amber))
        .task(id: store.revision) {
            let snap = await TrainingCache.shared.snapshot(store, app.repertoires)
            focus = snap.weaknesses.first
        }
    }

    private func range(_ w: WeekStats) -> String {
        let f = Date.FormatStyle().day().month(.abbreviated)
        return "\(w.start.formatted(f)) – \(Date().formatted(f))"
    }

    /// One sentence on how the week went.
    private func headline(_ w: WeekStats, _ l: WeekStats) -> some View {
        let text: String = {
            if w.games == 0 { return "No games this week yet. Your practice still counts." }
            if let a = w.blundersPerGame, let b = l.blundersPerGame, a < b - 0.2 { return "Fewer blunders than last week. The checking is working." }
            if let a = w.accuracy, let b = l.accuracy, a > b + 1 { return "Sharper than last week: your accuracy is up." }
            if let a = w.blundersPerGame, let b = l.blundersPerGame, a > b + 0.2 { return "More blunders than last week. Do a blunder check before your next game." }
            return "A steady week. Keep the daily practice going."
        }()
        return Text(text).font(.system(size: 22, weight: .bold)).tracking(-0.4).foregroundStyle(BC.ink)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
    }

    private func tile<D: View>(_ label: String, _ value: String, _ sub: String?, @ViewBuilder delta: () -> D) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabelText(label)
            Text(value).font(.bcStat).foregroundStyle(BC.ink).lineLimit(1).minimumScaleFactor(0.6)
            Group {
                if let sub { Text(sub).foregroundStyle(BC.mute) } else { delta() }
            }
            .font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BC.card, in: RoundedRectangle(cornerRadius: BC.rRow, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BC.rRow, style: .continuous).stroke(BC.line, lineWidth: 1))
    }

    private func chart(_ w: WeekStats) -> some View {
        CardBox(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                LabelText("Accuracy by day")
                Chart(w.byDay, id: \.0) { d in
                    BarMark(x: .value("Day", d.0, unit: .day), y: .value("Accuracy", d.1))
                        .foregroundStyle(d.1 >= (w.accuracy ?? 0) ? BC.mint : BC.coral.opacity(0.8))
                        .cornerRadius(4)
                }
                .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.narrow)).foregroundStyle(BC.mute) } }
                .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(BC.line); AxisValueLabel().foregroundStyle(BC.mute) } }
                .frame(height: 130)
            }
        }
    }

    private func bestGame(_ g: GameRecord) -> some View {
        Button { Feel.tick(); app.open(.game(g.id)) } label: {
            HStack(spacing: 12) {
                IconTile(systemImage: "star.fill", colour: BC.amber)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Best game: \(String(format: "%.1f", g.userAccuracy ?? 0))").font(.bcRowTitle).foregroundStyle(BC.ink)
                    Text("vs \(g.opponent) · \(g.opening)").font(.bcCaption).foregroundStyle(BC.mute).lineLimit(1)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.forward").font(.system(size: 13, weight: .semibold)).foregroundStyle(BC.mute)
            }
            .padding(14)
            .background(BC.card, in: RoundedRectangle(cornerRadius: BC.rRow, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: BC.rRow, style: .continuous).stroke(BC.line, lineWidth: 1))
        }
        .buttonStyle(PressStyle())
    }

    /// The one thing to work on next week, with the drill for it.
    private func focusCard(_ f: Weakness) -> some View {
        CardBox {
            VStack(alignment: .leading, spacing: 12) {
                LabelText("Next week's focus", colour: BC.coral)
                HStack(spacing: 12) {
                    IconTile(systemImage: f.icon, colour: BC.coral, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.title).font(.bcCardTitle).foregroundStyle(BC.ink).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        Text(f.summary).font(.bcCaption).foregroundStyle(BC.mute)
                    }
                }
                BlockButton(title: [.hanging, .losingMaterial, .allowedMate, .missedChances].contains(f.kind) ? "Blunder check" : "Train this",
                            systemImage: "play.fill") {
                    if [.hanging, .losingMaterial, .allowedMate, .missedChances].contains(f.kind) { app.open(.blunderCheck) }
                    else { app.open(.weakness(f.kind.rawValue)) }
                }
            }
        }
    }
}
