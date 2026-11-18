import SwiftUI

/// The Games tab: your chess.com games, newest first, with their marks and accuracy.
struct GamesView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var progress: ProgressStore
    @EnvironmentObject var store: GameStore
    @AppStorage("games2.sort") private var sortRaw = GameSort.newest.rawValue
    @AppStorage("games2.filter") private var filterRaw = GameFilter.all.rawValue
    @AppStorage("games2.speed") private var speed = "all"
    @State private var cache = GamesCache()

    private var sort: GameSort { GameSort(rawValue: sortRaw) ?? .newest }
    private var filter: GameFilter { GameFilter(rawValue: filterRaw) ?? .all }
    private var linked: Bool { progress.settings.linked }

    var body: some View {
        let rows = linked ? cache.rows(store: store, sort: sort, filter: filter, speed: speed) : []
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header.padding(.bottom, BC.gap).arrive(0)
                if !linked {
                    EmptyCard(title: "Bring in your games",
                              message: "Link your chess.com name. Every game gets marked like chess.com: brilliant moves, blunders and the best move each time.",
                              actionTitle: "Link chess.com") { app.open(.link) }
                        .arrive(1)
                } else {
                    if let err = store.lastError {
                        Text(err).font(.bcCaption).foregroundStyle(BC.coral).padding(.bottom, 10)
                    }
                    filters.padding(.bottom, 12).arrive(1)
                    analyseCard(rows).padding(.bottom, 12).arrive(2)
                    if rows.isEmpty {
                        emptyState.arrive(3)
                    } else {
                        ForEach(rows) { r in
                            Button { Feel.tick(); app.open(.game(r.id)) } label: {
                                GameRowView(info: r, live: store.live)
                            }
                            .buttonStyle(PressStyle())
                            .padding(.bottom, 8)
                        }
                    }
                }
            }
            .padding(.horizontal, BC.side)
            .padding(.top, BC.top)
            .padding(.bottom, BC.dockClearance + 12)
            .readableColumn()
        }
        .scrollIndicators(.hidden)
        .topFade()
        // Its own task: letting go of the pull doesn't cancel the download.
        .refreshable { await Task { await sync() }.value }
        .background(Spotlight(colour: BC.mint))
    }

    // MARK: Header

    private var header: some View {
        TabHeader(title: "Games", subtitle: linked && store.importing ? store.status : nil) {
            if linked {
                HStack(spacing: 10) {
                    controls
                    CircleButton(systemImage: store.importing ? "ellipsis" : "arrow.triangle.2.circlepath",
                                 label: "Sync with chess.com") {
                        Task { await sync() }
                    }
                }
            }
        }
    }

    private func sync() async {
        let s = progress.settings
        await store.sync(user: s.chessComUser, months: s.historyMonths, autoReview: s.autoReview)
    }

    // MARK: Analyse

    @ViewBuilder
    private func analyseCard(_ shown: [GamesCache.Info]) -> some View {
        // The live part redraws on its own as reviews tick along; the rest only when the games change.
        let waiting = cache.unreviewed(store: store)
        ReviewStatusReader(status: store.live) { live in
            analyseCard(shown, pending: live.pending, ring: live.progress, waiting: waiting)
        }
    }

    @ViewBuilder
    private func analyseCard(_ shown: [GamesCache.Info], pending: Int, ring: Double, waiting: [GameRecord]) -> some View {
        if pending > 0 {
            HStack(spacing: 10) {
                ProgressRingSmall(value: ring)
                Text("Analysing · \(pending) left").font(.system(size: 15, weight: .semibold).monospacedDigit()).foregroundStyle(BC.ink)
                Spacer(minLength: 6)
                Button("Stop") { Feel.tick(); store.cancelReviews() }.buttonStyle(PillButton())
            }
            .padding(.leading, 14).padding(.trailing, 8).frame(height: 54)
            .background(BC.card, in: Capsule())
            .overlay(Capsule().stroke(BC.line, lineWidth: 1))
        } else if !waiting.isEmpty {
            let shownIDs = Set(shown.filter { !$0.reviewed }.map(\.id))
            let week = waiting.filter { $0.endTime > Date().addingTimeInterval(-7 * 86_400) }.map(\.id)
            let month = waiting.filter { $0.endTime > Date().addingTimeInterval(-30 * 86_400) }.map(\.id)
            let narrowed = filter != .all || speed != "all"
            HStack(spacing: 10) {
                    Image(systemName: "sparkle.magnifyingglass").font(.system(size: 15, weight: .semibold)).foregroundStyle(BC.violet)
                    Text("\(waiting.count) not analysed").font(.system(size: 15, weight: .semibold).monospacedDigit())
                        .foregroundStyle(BC.ink).lineLimit(1)
                    Spacer(minLength: 6)
                    Menu {
                        Section("Analyse with Stockfish") {
                            Button("All \(waiting.count) games") { analyse(waiting.map(\.id)) }
                            if !week.isEmpty { Button("Last 7 days (\(week.count))") { analyse(week) } }
                            if !month.isEmpty, month.count != week.count { Button("Last 30 days (\(month.count))") { analyse(month) } }
                            if narrowed, !shownIDs.isEmpty {
                                Button("This filter (\(shownIDs.count))") {
                                    analyse(waiting.map(\.id).filter(shownIDs.contains))
                                }
                            }
                        }
                    } label: {
                        Text("Analyse").font(.system(size: 14, weight: .semibold)).foregroundStyle(BC.ink)
                            .padding(.horizontal, 15).frame(height: 38)
                            .background(BC.raised, in: Capsule())
                            .overlay(Capsule().stroke(BC.line, lineWidth: 1))
                    }
                    .accessibilityLabel("Analyse games")
            }
            .padding(.leading, 16).padding(.trailing, 8).frame(height: 54)
            .background(BC.card, in: Capsule())
            .overlay(Capsule().stroke(BC.line, lineWidth: 1))
        }
    }

    private func analyse(_ ids: [String]) {
        Feel.tap()
        store.enqueueReviews(ids)
    }

    // MARK: Sort, speed, range

    private var speeds: [String] {
        let present = Set(store.games.map(\.timeClass))
        return ["rapid", "blitz", "bullet", "daily"].filter { present.contains($0) || $0 == speed }
    }

    /// Sort, speed and how far back, in one round button.
    private var controls: some View {
        Menu {
            Picker("Sort", selection: $sortRaw) {
                ForEach(GameSort.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }
            Menu("Speed · \(speed == "all" ? "All" : speed.capitalized)") {
                Picker("Speed", selection: $speed) {
                    Text("All speeds").tag("all")
                    ForEach(speeds, id: \.self) { Text($0.capitalized).tag($0) }
                }
            }
            Menu("Since · \(AppSettings.historyName(progress.settings.historyMonths))") {
                Picker("History", selection: $progress.settings.historyMonths) {
                    ForEach(AppSettings.historyOptions, id: \.0) { Text($0.1).tag($0.0) }
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease").font(.system(size: 17, weight: .semibold))
                .foregroundStyle(sort != .newest || speed != "all" ? BC.mint : BC.ink)
                .frame(width: 42, height: 42)
                .background(BC.card, in: Circle())
                .overlay(Circle().stroke(BC.line, lineWidth: 1))
        }
        .accessibilityLabel("Sort and filter")
        .onChange(of: sortRaw) { _, _ in Feel.tick() }
        .onChange(of: speed) { _, _ in Feel.tick() }
    }

    // MARK: Filters

    private var filters: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(GameFilter.allCases, id: \.rawValue) { f in
                        Chip(title: f.title, dot: f.dot, active: filter == f) {
                            withAnimation(BC.curve(0.24)) {
                                filterRaw = f.rawValue
                                if let s = f.sort { sortRaw = s.rawValue }
                            }
                        }
                        .id(f.rawValue)
                    }
                }
                .padding(.horizontal, BC.side)
            }
            .scrollIndicators(.hidden)
            .padding(.horizontal, -BC.side)
            .onAppear { proxy.scrollTo(filterRaw, anchor: .center) }
            .onChange(of: filterRaw) { _, f in withAnimation(BC.curve(0.3)) { proxy.scrollTo(f, anchor: .center) } }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if store.games.isEmpty && store.importing {
            EmptyCard(title: "Bringing in your games", message: store.status ?? "Fetching your games from chess.com.")
        } else if store.games.isEmpty {
            EmptyCard(title: "No games yet", message: "Nothing in the \(AppSettings.historyName(progress.settings.historyMonths).lowercased()) window. Sync to fetch the newest games.",
                      actionTitle: "Sync with chess.com") { Task { await sync() } }
        } else {
            EmptyCard(title: "No games here", message: "Nothing matches these filters.", actionTitle: "Show all games") {
                withAnimation(BC.curve(0.24)) { filterRaw = GameFilter.all.rawValue; speed = "all" }
            }
        }
    }
}

// MARK: - Sort and filter

enum GameSort: String, CaseIterable {
    case newest, oldest, accuracyHigh, accuracyLow, brilliant, great, blunders, opponent
    var title: String {
        switch self {
        case .newest: "Newest first"
        case .oldest: "Oldest first"
        case .accuracyHigh: "Highest accuracy"
        case .accuracyLow: "Lowest accuracy"
        case .brilliant: "Most brilliant"
        case .great: "Most great"
        case .blunders: "Most blunders"
        case .opponent: "Strongest opponent"
        }
    }
    var short: String {
        switch self {
        case .newest: "Newest"
        case .oldest: "Oldest"
        case .accuracyHigh: "Best accuracy"
        case .accuracyLow: "Worst accuracy"
        case .brilliant: "Most !!"
        case .great: "Most !"
        case .blunders: "Most ??"
        case .opponent: "Strongest opponent"
        }
    }
}

enum GameFilter: String, CaseIterable {
    case all, wins, losses, brilliant, great, blunders, white, black
    var title: String {
        switch self {
        case .all: "All"
        case .wins: "Wins"
        case .losses: "Losses"
        case .brilliant: "!! Brilliant"
        case .great: "! Only moves"
        case .blunders: "?? Blunders"
        case .white: "As White"
        case .black: "As Black"
        }
    }
    var dot: Color? {
        switch self {
        case .brilliant: MoveClass.brilliant.colour
        case .great: MoveClass.great.colour
        case .blunders: MoveClass.blunder.colour
        default: nil
        }
    }
    /// Choosing a mark sorts by it.
    var sort: GameSort? {
        switch self {
        case .brilliant: .brilliant
        case .great: .great
        case .blunders: .blunders
        default: nil
        }
    }
}

// MARK: - Cache

/// Everything a row shows, worked out once per store revision; the sorted list is cached per choice.
final class GamesCache {
    struct Info: Identifiable {
        let id: String
        let result: GameResult
        let opponent: String
        let rating: Int
        let line: String
        let brilliant: Int
        let great: Int
        let blunders: Int
        let accuracy: Double?
        let reviewed: Bool
        let endTime: Date
        let color: PieceColor
        let timeClass: String
    }

    private var infoKey = -1
    private var infos: [Info] = []
    private var listKey = ""
    private var list: [Info] = []
    /// Each game's row, kept until its review changes; all of them are redone once a minute ("5 min ago").
    private var byID: [String: (stamp: Date?, info: Info)] = [:]
    private var builtAt = Date.distantPast
    private var waitingKey = -1
    private var waiting: [GameRecord] = []

    /// Games not reviewed yet, worked out once per change to the games.
    @MainActor
    func unreviewed(store: GameStore) -> [GameRecord] {
        if waitingKey != store.gamesVersion {
            waitingKey = store.gamesVersion
            waiting = store.unreviewed
        }
        return waiting
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.dateTimeStyle = .named
        return f
    }()

    @MainActor
    func rows(store: GameStore, sort: GameSort, filter: GameFilter, speed: String) -> [Info] {
        let now = Date()
        if infoKey != store.gamesVersion || now.timeIntervalSince(builtAt) > 60 {
            infoKey = store.gamesVersion
            if now.timeIntervalSince(builtAt) > 60 {
                byID = [:]
                builtAt = now
            }
            infos = store.games.map { g in
                let reviewed = g.review?.version == GameReview.currentVersion
                let stamp = reviewed ? g.review?.reviewedAt : nil
                if let hit = byID[g.id], hit.stamp == stamp { return hit.info }
                let info = Self.info(g, reviewed: reviewed, now: now)
                byID[g.id] = (stamp, info)
                return info
            }
            listKey = ""
        }
        let key = "\(sort.rawValue)|\(filter.rawValue)|\(speed)"
        if key != listKey {
            listKey = key
            let kept = infos.filter { i in
                if speed != "all" && i.timeClass != speed { return false }
                switch filter {
                case .all: return true
                case .wins: return i.result == .win
                case .losses: return i.result == .loss
                case .brilliant: return i.brilliant > 0
                case .great: return i.great > 0
                case .blunders: return i.blunders > 0
                case .white: return i.color == .white
                case .black: return i.color == .black
                }
            }
            func by(_ key: (Info) -> Double) -> [Info] {
                kept.sorted { let a = key($0), b = key($1); return a == b ? $0.endTime > $1.endTime : a > b }
            }
            switch sort {
            case .newest: list = kept.sorted { $0.endTime > $1.endTime }
            case .oldest: list = kept.sorted { $0.endTime < $1.endTime }
            case .accuracyHigh: list = by { $0.accuracy ?? -1 }
            case .accuracyLow: list = by { -($0.accuracy ?? 1000) }
            case .brilliant: list = by { Double($0.brilliant) }
            case .great: list = by { Double($0.great) }
            case .blunders: list = by { Double($0.blunders) }
            case .opponent: list = by { Double($0.rating) }
            }
        }
        return list
    }

    private static func info(_ g: GameRecord, reviewed: Bool, now: Date) -> Info {
        var b = 0, gr = 0, bl = 0
        if reviewed, let r = g.review {
            for (i, c) in r.classes.enumerated() where g.moverAt(i) == g.userColor {
                if c == .brilliant { b += 1 } else if c == .great { gr += 1 } else if c == .blunder { bl += 1 }
            }
        }
        let when = relative.localizedString(for: g.endTime, relativeTo: now)
        return Info(id: g.id, result: g.result, opponent: g.opponent, rating: g.opponentRating,
                    line: "\(shortFamily(g.family)) · \(g.timeClass.capitalized) · \(when)",
                    brilliant: b, great: gr, blunders: bl,
                    accuracy: reviewed ? g.userAccuracy : nil, reviewed: reviewed,
                    endTime: g.endTime, color: g.userColor, timeClass: g.timeClass)
    }

    /// "Caro-Kann Defense" → "Caro-Kann", "Italian Game" → "Italian".
    static func shortFamily(_ f: String) -> String {
        for suffix in [" Defense", " Opening", " Game"] where f.hasSuffix(suffix) && f.count > suffix.count + 2 {
            return String(f.dropLast(suffix.count))
        }
        return f
    }
}

// MARK: - Pieces

/// A small ring for work in progress.
private struct ProgressRingSmall: View {
    let value: Double
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.1), lineWidth: 3)
            Circle().trim(from: 0, to: max(0.03, value))
                .stroke(BC.violet, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(BC.curve(0.4), value: value)
        }
        .frame(width: 22, height: 22)
    }
}

private struct GameRowView: View {
    let info: GamesCache.Info
    let live: ReviewStatus

    var body: some View {
        HStack(spacing: 12) {
            ResultSquare(result: info.result)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text("vs \(info.opponent)").font(.bcRowTitle).foregroundStyle(BC.ink).lineLimit(1)
                    Text("(\(info.rating))").font(.bcCaption.monospacedDigit()).foregroundStyle(BC.mute).fixedSize()
                }
                Text(info.line).font(.bcCaption).foregroundStyle(BC.mute).lineLimit(1).minimumScaleFactor(0.85)
                if info.brilliant + info.great + info.blunders > 0 {
                    HStack(spacing: 5) {
                        if info.brilliant > 0 { Tag(text: "!! \(info.brilliant)", colour: MoveClass.brilliant.colour) }
                        if info.great > 0 { Tag(text: "! \(info.great)", colour: MoveClass.great.colour) }
                        if info.blunders > 0 { Tag(text: "?? \(info.blunders)", colour: MoveClass.blunder.colour) }
                    }
                    .padding(.top, 3)
                }
            }
            Spacer(minLength: 6)
            // Only this corner follows the reviewer's progress.
            ReviewStatusReader(status: live) { l in
                accuracy(reviewing: l.reviewingID == info.id, progress: l.reviewingID == info.id ? l.progress : 0)
            }
            .frame(minWidth: 54, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(BC.card, in: RoundedRectangle(cornerRadius: BC.rRow, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BC.rRow, style: .continuous).stroke(BC.line, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: BC.rRow, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func accuracy(reviewing: Bool, progress: Double) -> some View {
        if reviewing {
            ZStack {
                Circle().stroke(Color.white.opacity(0.1), lineWidth: 3)
                Circle().trim(from: 0, to: max(0.03, progress))
                    .stroke(BC.violet, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(BC.curve(0.4), value: progress)
            }
            .frame(width: 24, height: 24)
            .accessibilityLabel("Analysing")
        } else {
            VStack(alignment: .trailing, spacing: 1) {
                Text(info.accuracy.map { String(format: "%.1f", $0) } ?? "–")
                    .font(.system(size: 17, weight: .bold).monospacedDigit())
                    .foregroundStyle(info.reviewed ? BC.ink : BC.mute)
                Text("accuracy").font(.system(size: 11)).foregroundStyle(BC.mute)
            }
        }
    }
}

/// The W / L / D square.
struct ResultSquare: View {
    let result: GameResult
    var size: CGFloat = 36
    var body: some View {
        let fill: Color = result == .win ? BC.mint : result == .loss ? BC.coral : BC.raised2
        Text(result.letter).font(.system(size: size * 0.42, weight: .heavy))
            .foregroundStyle(result == .draw ? BC.ink : .black)
            .frame(width: size, height: size)
            .background(fill, in: RoundedRectangle(cornerRadius: size * 0.33, style: .continuous))
            .accessibilityLabel(result == .win ? "Won" : result == .loss ? "Lost" : "Draw")
    }
}
