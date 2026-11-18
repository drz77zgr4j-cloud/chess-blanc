import SwiftUI

/// The Openings tab: study what you're learning, see what you actually play, and browse every opening.
struct OpeningsView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var progress: ProgressStore
    @EnvironmentObject var store: GameStore
    @AppStorage("openings.side") private var sideRaw = "white"
    @State private var showAllPlayed = false
    @State private var showAllLibrary = false
    @State private var spots: [String: TrainingSnapshot.OpeningSpot] = [:]
    @State private var statsCache = OpeningStatsCache()
    @State private var spotsRevision = -1
    @Environment(\.tabVisible) private var tabVisible

    private var side: PieceColor { sideRaw == "black" ? .black : .white }
    private var mine: [Repertoire] { app.repertoires.filter { $0.color == side } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BC.gap) {
                TabHeader(title: "Openings").arrive(0)
                ChipPicker(options: [("white", "White"), ("black", "Black")], selection: $sideRaw, scrolls: false)
                    .arrive(1)
                StudyCard(reps: mine, side: side).arrive(2)
                yours.arrive(3)
                played.arrive(4)
                libraryList.arrive(5)
            }
            .padding(.horizontal, BC.side)
            .padding(.top, BC.top)
            .padding(.bottom, BC.dockClearance)
            .readableColumn()
        }
        .scrollIndicators(.hidden)
        .topFade()
        .background(Spotlight(colour: BC.blue))
        .onChange(of: sideRaw) { _, _ in Feel.tick(); showAllPlayed = false; showAllLibrary = false }
        .task(id: tabVisible ? store.revision : -1) {
            guard tabVisible, spotsRevision != store.revision else { return }
            let revision = store.revision
            let snap = await TrainingCache.shared.snapshot(store, app.repertoires)
            spots = snap.openingNodes
            spotsRevision = revision
        }
    }

    // MARK: Yours

    @ViewBuilder
    private var yours: some View {
        if !mine.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                LabelText("Your repertoire").padding(.horizontal, 4).padding(.top, 8)
                ForEach(mine, id: \.id) { rep in
                    Button { Feel.tick(); app.open(.opening(rep.id)) } label: {
                        let cov = progress.coverage(rep)
                        PictureRow(title: rep.title, sub: "\(OpeningText.percent(cov)) known", dot: cov > 0 ? BC.mint : BC.faint) {
                            BoardThumb(fen: rep.setupFEN, flipped: side == .black)
                        } trailing: {
                            Image(systemName: "chevron.forward").font(.system(size: 13, weight: .semibold)).foregroundStyle(BC.mute)
                        }
                    }
                    .buttonStyle(PressStyle())
                }
            }
        }
    }

    // MARK: What you play

    @ViewBuilder
    private var played: some View {
        let stats = statsCache.stats(store, side: side)
        let total = max(1, stats.reduce(0) { $0 + $1.games })
        if !stats.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                LabelText("In your games").padding(.horizontal, 4).padding(.top, 8)
                RowGroup {
                    ForEach(showAllPlayed ? stats : Array(stats.prefix(6))) { o in
                        let target = destination(for: o)
                        Button {
                            guard let target else { return }
                            Feel.tick(); app.open(target)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Text(o.name).font(.bcRowTitle).foregroundStyle(BC.ink).lineLimit(1).minimumScaleFactor(0.8)
                                    Spacer(minLength: 4)
                                    Text("\(Int((Double(o.games) / Double(total) * 100).rounded()))%")
                                        .font(.system(size: 15, weight: .bold).monospacedDigit()).foregroundStyle(BC.ink)
                                    if target != nil {
                                        Image(systemName: "chevron.forward").font(.system(size: 13, weight: .semibold)).foregroundStyle(BC.mute)
                                    }
                                }
                                WDLBar(win: o.wins, draw: o.draws, loss: o.games - o.wins - o.draws)
                                HStack(spacing: 10) {
                                    Text("\(o.games) games").foregroundStyle(BC.mute)
                                    Text("\(o.wins) W").foregroundStyle(BC.mint)
                                    Text("\(o.draws) D").foregroundStyle(BC.mute)
                                    Text("\(o.games - o.wins - o.draws) L").foregroundStyle(BC.coral)
                                }
                                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            }
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if stats.count > 6 {
                        MoreButton(title: showAllPlayed ? "Show fewer" : "Show all \(stats.count)") { showAllPlayed.toggle() }
                    }
                }
            }
        }
    }

    /// Where an opening from your games leads: your repertoire at that position, else the library's page for it.
    private func destination(for o: GameStore.OpeningStat) -> Route? {
        if let spot = spots[o.id], app.isActive(spot.rep), app.repertoire(spot.rep)?.node(spot.node) != nil {
            return .explore(rep: spot.rep, node: spot.node)
        }
        if let e = libraryMatch(o.name, side: o.color) { return .opening(e.id) }
        return nil
    }

    private func libraryMatch(_ name: String, side: PieceColor) -> LibraryEntry? {
        func core(_ t: String) -> String {
            var s = t.lowercased()
            for w in [" defence", " defense", " opening", " game", " system"] { s = s.replacingOccurrences(of: w, with: "") }
            return s.trimmingCharacters(in: .whitespaces)
        }
        let n = core(name)
        guard !n.isEmpty else { return nil }
        return app.library.filter { $0.side == side }.first { n.contains(core($0.title)) || core($0.title).contains(n) }
    }

    // MARK: Library

    @ViewBuilder
    private var libraryList: some View {
        let all = app.library.filter { $0.side == side }.sorted { ($0.popularity ?? 0) > ($1.popularity ?? 0) }
        if !all.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                LabelText("Every opening").padding(.horizontal, 4).padding(.top, 8)
                ForEach(showAllLibrary ? all : Array(all.prefix(8))) { e in
                    Button { Feel.tick(); app.open(.opening(e.id)) } label: {
                        PictureRow(title: e.title, sub: e.setupSAN ?? e.blurb, dot: app.isActive(e.id) ? BC.mint : nil) {
                            BoardThumb(fen: e.fen ?? Chess.startFEN, flipped: e.side == .black)
                        } trailing: {
                            if app.isActive(e.id) {
                                Tag(text: "Yours", colour: BC.mint)
                            } else {
                                Image(systemName: "chevron.forward").font(.system(size: 13, weight: .semibold)).foregroundStyle(BC.mute)
                            }
                        }
                    }
                    .buttonStyle(PressStyle())
                }
                if all.count > 8 {
                    MoreButton(title: showAllLibrary ? "Show fewer" : "Show all \(all.count)") { showAllLibrary.toggle() }
                }
            }
        }
    }
}

/// "Show all 24" under a list.
struct MoreButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button {
            Feel.tick()
            withAnimation(BC.curve(0.3)) { action() }
        } label: {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(BC.mute)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A row picture: the half of the board where your pieces are, after the opening's setup.
struct BoardThumb: View {
    let fen: String
    var flipped = false
    var body: some View {
        MiniBoard(fen: fen, size: 76, flipped: flipped, radius: 0)
            .frame(width: 76, height: 54, alignment: .center)
            .clipped()
    }
}

/// Study what you're learning: a 15-minute session, new moves, or revision of what you know.
struct StudyCard: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var progress: ProgressStore
    let reps: [Repertoire]
    let side: PieceColor
    var title: String? = nil

    var body: some View {
        let cov = reps.isEmpty ? 0 : reps.map { progress.coverage($0) }.reduce(0, +) / Double(reps.count)
        let counts = reps.map { progress.counts($0) }
        let learned = counts.reduce(0) { $0 + $1.learned }
        let total = counts.reduce(0) { $0 + $1.total }
        let due = counts.reduce(0) { $0 + $1.due }
        let name = title ?? (side == .white ? "As White" : "As Black")
        CardBox {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 18) {
                    CoverageRing(value: cov)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name).font(.bcCardTitle).foregroundStyle(BC.ink).lineLimit(2).minimumScaleFactor(0.85)
                        Text("\(learned) of \(total) moves").font(.system(size: 14).monospacedDigit()).foregroundStyle(BC.mute)
                        if due > 0 {
                            Text("\(due) to review").font(.system(size: 14, weight: .semibold).monospacedDigit()).foregroundStyle(BC.coral)
                        }
                    }
                    Spacer(minLength: 0)
                }
                if reps.isEmpty {
                    Text("Pick an opening below and add it to your repertoire.").font(.bcBody).foregroundStyle(BC.mute)
                } else {
                    BlockButton(title: "15-minute session", systemImage: "play.fill") { go(.session, "Session") }
                    HStack(spacing: 10) {
                        SecondaryButton(title: "Learn new", systemImage: "sparkles", height: 48) { go(.learn, "New moves") }
                        SecondaryButton(title: "Revise", systemImage: "shuffle", height: 48) { go(.revise, "Revise") }
                            .opacity(learned == 0 ? 0.4 : 1)
                            .disabled(learned == 0)
                    }
                }
            }
        }
    }

    private func go(_ mode: PracticeRequest.Mode, _ label: String) {
        let t = reps.count == 1 ? "\(label) · \(reps[0].title)" : label
        app.open(.practice(PracticeRequest(repIDs: reps.map(\.id), mode: mode, title: t)))
    }
}

/// The share of real games where you'd know your move, as a ring.
struct CoverageRing: View {
    let value: Double
    var size: CGFloat = 86
    @State private var drawn = false
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.08), lineWidth: 7)
            Circle().trim(from: 0, to: drawn ? max(0.004, min(1, value)) : 0.004)
                .stroke(BC.mint, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: BC.mint.opacity(0.5), radius: 6)
                .animation(BC.curve(0.8), value: value)
            VStack(spacing: 0) {
                Text(OpeningText.percent(value)).font(.system(size: 22, weight: .bold).monospacedDigit())
                    .foregroundStyle(BC.ink).contentTransition(.numericText())
                Text("known").font(.system(size: 11, weight: .medium)).foregroundStyle(BC.mute)
            }
        }
        .frame(width: size, height: size)
        .onAppear { withAnimation(BC.curve(0.8).delay(0.2)) { drawn = true } }
        .accessibilityElement()
        .accessibilityLabel("You'd know your move in \(OpeningText.percent(value)) of real games")
    }
}

/// What you play, by opening: worked out once per change to your games, not on every redraw.
@MainActor
final class OpeningStatsCache {
    private var key: (Int, Int) = (-1, -1)
    private var all: [GameStore.OpeningStat] = []

    func stats(_ store: GameStore, side: PieceColor) -> [GameStore.OpeningStat] {
        if key != (store.revision, store.games.count) {
            key = (store.revision, store.games.count)
            all = store.openingStats()
        }
        return all.filter { $0.color == side }
    }
}
