import SwiftUI

/// One opening: how it's set up, how much of it you know, its lines (most common first),
/// what it could also turn into before it's set up, and its traps.
struct OpeningPage: View {
    let repID: String
    @EnvironmentObject var app: AppModel
    @State private var rep: Repertoire?
    @State private var failed = false

    var body: some View {
        Group {
            if let rep {
                OpeningScreen(rep: rep)
            } else {
                VStack(spacing: BC.gap) {
                    NavBar(title: app.library.first { $0.id == repID }?.title ?? "Opening")
                    if failed {
                        EmptyCard(title: "Couldn't open this", message: "The opening's lines didn't load.")
                            .padding(.horizontal, BC.side)
                    } else {
                        ProgressView().tint(BC.ink).padding(.top, 60)
                    }
                    Spacer()
                }
                .background(Spotlight(colour: BC.blue))
            }
        }
        .task {
            guard rep == nil else { return }
            rep = await app.pack(repID)
            failed = rep == nil
        }
    }
}

private struct OpeningScreen: View {
    let rep: Repertoire
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var progress: ProgressStore
    @State private var depth: StudyDepth
    @State private var allLines = false
    @State private var allTraps = false
    @State private var confirmRemove = false

    init(rep: Repertoire) {
        self.rep = rep
        _depth = State(initialValue: StudyDepth.of(rep.id))
    }

    private var active: Bool { app.isActive(rep.id) }

    var body: some View {
        let titles = OpeningText.distinctTitles(rep.chapters)
        let deviations = rep.chapters.filter { rep.isDeviation($0) }
        let lines = rep.chapters.filter { !rep.isDeviation($0) }
        VStack(spacing: 0) {
            NavBar(title: rep.title)
            ScrollView {
                VStack(alignment: .leading, spacing: BC.gap) {
                    hero.arrive(0)
                    study.arrive(1)
                    depthPicker.arrive(2)
                    if !lines.isEmpty {
                        section("Lines", lines, titles, limit: allLines ? lines.count : 8, more: lines.count > 8) { allLines.toggle() }
                            .arrive(3)
                    }
                    if !deviations.isEmpty {
                        section("Could also turn into", deviations, titles, limit: deviations.count, more: false) {}
                            .arrive(4)
                    }
                    traps.arrive(5)
                    if active {
                        QuietButton(title: "Remove from my repertoire", colour: BC.faint) { confirmRemove = true }
                            .frame(maxWidth: .infinity).padding(.top, 8)
                    }
                }
                .padding(.horizontal, BC.side)
                .padding(.top, 8)
                .padding(.bottom, 40)
                .readableColumn()
            }
            .scrollIndicators(.hidden)
        }
        .background(Spotlight(colour: BC.blue))
        .confirmationDialog("Remove \(rep.title)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { app.setActive(rep.id, false); Feel.tick() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It leaves your daily practice. What you've learned is kept if you add it back.")
        }
    }

    // MARK: Hero

    private var hero: some View {
        let setup = rep.setupNode.map { rep.mainLineText(to: $0) } ?? ""
        return VStack(alignment: .leading, spacing: 12) {
            GeometryReader { geo in
                MiniBoard(fen: rep.setupFEN, size: geo.size.width, flipped: rep.color == .black,
                          highlight: rep.setupNode.map { [$0.from, $0.to] } ?? [], radius: 18)
            }
            .aspectRatio(1, contentMode: .fit)
            VStack(alignment: .leading, spacing: 4) {
                if !setup.isEmpty {
                    Text(setup).font(.system(size: 15, weight: .semibold).monospacedDigit()).foregroundStyle(BC.ink)
                }
                Text(rep.blurb).font(.bcBody).foregroundStyle(BC.mute).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: Study

    @ViewBuilder
    private var study: some View {
        if active {
            StudyCard(reps: [rep], side: rep.color, title: rep.title)
        } else {
            CardBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 18) {
                        CoverageRing(value: progress.coverage(rep))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Not in your repertoire").font(.bcCardTitle).foregroundStyle(BC.ink)
                            Text("\(progress.counts(rep).total) moves to learn").font(.system(size: 14).monospacedDigit()).foregroundStyle(BC.mute)
                        }
                        Spacer(minLength: 0)
                    }
                    BlockButton(title: "Add to my repertoire", systemImage: "plus") {
                        app.setActive(rep.id, true)
                        Feel.success()
                    }
                    SecondaryButton(title: "Try a few lines first", systemImage: "sparkles", height: 48) {
                        app.open(.practice(PracticeRequest(repID: rep.id, mode: .learn, title: "Try · \(rep.title)")))
                    }
                }
            }
        }
    }

    // MARK: Depth

    private var depthPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabelText("New moves come from").padding(.horizontal, 4)
            ChipPicker(options: StudyDepth.allCases.map { ($0, $0.title) }, selection: $depth, scrolls: false)
                .onChange(of: depth) { _, d in StudyDepth.set(d, for: rep.id); Feel.tick() }
        }
    }

    // MARK: Lines

    private func section(_ title: String, _ chapters: [Chapter], _ titles: [String: String], limit: Int, more: Bool,
                         toggle: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            LabelText(title).padding(.horizontal, 4).padding(.top, 8)
            ForEach(chapters.prefix(limit)) { ch in
                let name = titles[ch.id] ?? ch.title
                Button { Feel.tick(); app.open(.explore(rep: rep.id, node: ch.entry.id)) } label: {
                    ChapterPictureRow(rep: rep, chapter: ch, title: name) {
                        app.open(.practice(PracticeRequest(repID: rep.id, mode: .all, nodeID: ch.entry.id, title: name)))
                    }
                }
                .buttonStyle(PressStyle())
            }
            if more {
                MoreButton(title: limit < chapters.count ? "Show all \(chapters.count)" : "Show fewer", action: toggle)
            }
        }
    }

    // MARK: Traps

    @ViewBuilder
    private var traps: some View {
        if !rep.traps.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                LabelText("Traps to know").padding(.horizontal, 4).padding(.top, 8)
                RowGroup {
                    ForEach(rep.traps.prefix(allTraps ? 30 : 5), id: \.id) { t in
                        Button { Feel.tick(); app.open(.explore(rep: rep.id, node: t.id)) } label: {
                            HStack(spacing: 12) {
                                IconTile(systemImage: "bolt.fill", colour: BC.amber, size: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("After \(t.numbered)").font(.bcRowTitle).foregroundStyle(BC.ink).lineLimit(1)
                                    Text(t.shortName ?? t.openingName ?? "They go wrong, you win material")
                                        .font(.bcCaption).foregroundStyle(BC.mute).lineLimit(1)
                                }
                                Spacer(minLength: 6)
                                Image(systemName: "chevron.forward").font(.system(size: 13, weight: .semibold)).foregroundStyle(BC.mute)
                            }
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if rep.traps.count > 5 {
                        MoreButton(title: allTraps ? "Show fewer" : "Show all \(min(30, rep.traps.count))") { allTraps.toggle() }
                    }
                }
            }
        }
    }
}

/// A line: the position it starts from, its name, how much you know, a play button.
struct ChapterPictureRow: View {
    @EnvironmentObject var progress: ProgressStore
    let rep: Repertoire
    let chapter: Chapter
    let title: String
    let practise: () -> Void

    var body: some View {
        let cov = progress.coverage(rep, in: chapter)
        let due = progress.counts(rep, in: chapter).due
        let dot = due > 0 ? BC.coral : cov >= 0.85 ? BC.mint : cov > 0 ? BC.blue : BC.faint
        PictureRow(title: title, sub: due > 0 ? "\(due) due" : "\(OpeningText.percent(cov)) known · \(chapter.entry.numbered)", dot: dot) {
            BoardThumb(fen: chapter.entry.fenAfter, flipped: rep.color == .black)
        } trailing: {
            Button { Feel.tick(); practise() } label: {
                Image(systemName: "play.fill").font(.system(size: 14, weight: .bold)).foregroundStyle(.black)
                    .frame(width: 40, height: 40)
                    .background(Color.white, in: Circle())
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("Practise \(title)")
        }
    }
}

extension Repertoire {
    /// "1.e4 e5 2.Nf3 Nc6 3.c3" up to this node.
    func mainLineText(to n: RepNode) -> String {
        var path: [RepNode] = []
        var cur: RepNode? = n
        while let c = cur, !c.isRoot { path.insert(c, at: 0); cur = c.parent }
        return path.enumerated().map { i, p in
            p.mover == .white ? "\(i / 2 + 1).\(p.san)" : (i == 0 ? "1…\(p.san)" : p.san)
        }.joined(separator: " ")
    }
}
