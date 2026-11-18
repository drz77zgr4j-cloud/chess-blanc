import SwiftUI

/// One leak: what it is, why it costs you, how to fix it, and your own positions to train it on.
struct WeaknessView: View {
    let kind: String
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: GameStore
    @State private var weakness: Weakness?
    @State private var loaded = false

    private var set: PuzzleSet {
        PuzzleSet(source: .weakness(kind), title: shortTitle)
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: shortTitle)
            ScrollView {
                if let w = weakness {
                    content(w).padding(.horizontal, BC.side).padding(.top, 4).padding(.bottom, 120)
                        .readableColumn()
                } else if loaded {
                    EmptyCard(title: "Not a leak any more", message: "This doesn't show up in your reviewed games right now.")
                        .padding(.horizontal, BC.side).padding(.top, 8)
                        .readableColumn()
                }
            }
            .scrollIndicators(.hidden)
        }
        .background(Spotlight(colour: BC.coral, strength: 0.26))
        .safeAreaInset(edge: .bottom) {
            if let w = weakness {
                Group {
                    if w.examples.isEmpty {
                        BlockButton(title: w.kind == .conversion ? "Practise core endgames" : "Review more games",
                                    systemImage: w.kind == .conversion ? "flag.checkered" : "play.fill") {
                            if w.kind == .conversion { app.open(.endgames) } else { app.go(.games) }
                        }
                    } else {
                        BlockButton(title: "Train this · \(w.examples.count) position\(w.examples.count == 1 ? "" : "s")", systemImage: "play.fill") {
                            PuzzleLaunch.startSolving(set)
                            app.open(.puzzles(set))
                        }
                    }
                }
                .padding(.horizontal, BC.side).padding(.top, 10).padding(.bottom, 6)
                .readableColumn()
                .background(LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .center).ignoresSafeArea())
            }
        }
        .task(id: store.revision) {
            let snap = await TrainingCache.shared.snapshot(store, app.repertoires)
            weakness = snap.weaknesses.first { $0.kind.rawValue == kind }
            loaded = true
        }
    }

    /// Title for the header and the run: "Hanging pieces".
    private var shortTitle: String {
        guard let k = Weakness.Kind(rawValue: kind) else { return "Your leak" }
        return switch k {
        case .hanging: "Hanging pieces"
        case .missedChances: "Missed chances"
        case .allowedMate: "Walking into mate"
        case .losingMaterial: "Losing material"
        case .timeTrouble: "Time trouble"
        case .leftPrep: "Leaving your prep"
        case .conversion: "Converting wins"
        case .drifting: "Drifting moves"
        }
    }

    private func content(_ w: Weakness) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                IconTile(systemImage: w.icon, colour: BC.coral, size: 52)
                Text(w.title).font(.system(size: 28, weight: .bold)).tracking(-0.5).foregroundStyle(BC.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .arrive(0)

            HStack(spacing: 8) {
                StatCard(label: "Times", value: "\(w.count)", context: "slips")
                StatCard(label: "Games", value: "\(w.games)", context: "of \(store.reviewed.count)")
                StatCard(label: "Cost", value: String(format: "%.1f", w.pointsLost), context: "points", colour: BC.coral)
            }
            .arrive(1)

            explain("Why it costs you", w.why, icon: "exclamationmark.circle", colour: BC.coral).arrive(2)
            explain("How to fix it", w.how, icon: "wrench.and.screwdriver", colour: BC.mint).arrive(3)
            if [.hanging, .losingMaterial, .allowedMate, .missedChances].contains(w.kind) {
                SecondaryButton(title: "Blunder check: train the habit", systemImage: "shield.lefthalf.filled", height: 50) {
                    app.open(.blunderCheck)
                }
                .arrive(3)
            }

            if !w.examples.isEmpty {
                SectionBox(title: "From your games") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 12) {
                        ForEach(w.examples.prefix(12)) { p in
                            Button {
                                PuzzleLaunch.start(set, at: p.id)
                                app.open(.puzzles(set))
                            } label: { example(p) }
                                .buttonStyle(PressStyle())
                        }
                    }
                }
                .arrive(4)
            }
        }
    }

    private func explain(_ title: String, _ text: String, icon: String, colour: Color) -> some View {
        CardBox(padding: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.system(size: 12, weight: .bold)).foregroundStyle(colour)
                    LabelText(title, colour: colour)
                }
                Text(text).font(.bcBody).foregroundStyle(BC.ink).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func example(_ p: Puzzle) -> some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 5) {
                SlipBoard(fen: p.fen, size: geo.size.width, flipped: p.side == .black, move: p.playedMove, radius: 12)
                HStack(spacing: 4) {
                    Text(p.playedText).font(.system(size: 12, weight: .semibold)).foregroundStyle(BC.ink)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    if p.cls.isSlip { Text(p.cls.symbol).font(.system(size: 12, weight: .heavy)).foregroundStyle(p.cls.colour) }
                }
            }
        }
        .aspectRatio(0.84, contentMode: .fit)
    }
}
