import SwiftUI

/// The training session: play your lines from memory, learn new moves, review what's due.
struct PracticeView: View {
    let request: PracticeRequest
    @StateObject private var session: PracticeSession

    init(request: PracticeRequest) {
        self.request = request
        _session = StateObject(wrappedValue: PracticeSession(request: request,
                                                             reps: request.repID == nil && request.repIDs == nil ? AppModel.shared.repertoires : AppModel.shared.allLoaded,
                                                             progress: AppModel.shared.progress))
    }

    var body: some View {
        PracticeScreen(session: session)
    }
}

private struct PracticeScreen: View {
    @ObservedObject var session: PracticeSession
    @EnvironmentObject var progress: ProgressStore
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var why: WhyTarget?
    @State private var started = false

    struct WhyTarget: Identifiable {
        let rep: Repertoire
        let node: RepNode
        let fen: String
        let peekNote: String?
        var id: String { node.id + fen }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(back: "End", title: session.request.title, subtitle: navSubtitle, onBack: end)
            if session.phase == .playing {
                capsules.padding(.horizontal, BC.side).padding(.top, 4).padding(.bottom, 12)
                    .readableColumn(BC.boardColumn)
                playing
            } else if session.phase == .summary {
                PracticeSummary(session: session, done: end)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                emptyState
            }
        }
        .background(Spotlight(colour: BC.blue, strength: 0.28))
        .onAppear {
            guard !started else { return }
            started = true
            session.begin()
        }
        .onDisappear { session.stop() }
        .sheet(item: $why) { t in
            WhySheet(rep: t.rep, node: t.node, fen: t.fen, peekNote: t.peekNote)
                .presentationDetents([.large])
        }
    }

    private var navSubtitle: String? {
        guard session.phase == .playing, !session.lines.isEmpty else { return nil }
        return "Line \(session.current + 1) of \(session.lines.count)"
    }

    private func end() {
        session.stop()
        dismiss()
    }

    // MARK: Progress row

    private var capsules: some View {
        HStack(spacing: 4) {
            ForEach(Array(session.outcomes.enumerated()), id: \.offset) { i, o in
                Capsule()
                    .fill(colour(o, current: i == session.current))
                    .frame(height: 5)
                    .frame(maxWidth: .infinity)
            }
        }
        .animation(BC.curve(0.3), value: session.current)
        .accessibilityElement()
        .accessibilityLabel("Line \(session.current + 1) of \(session.lines.count)")
    }

    private func colour(_ o: PracticeSession.Outcome, current: Bool) -> Color {
        switch o {
        case .clean: BC.mint
        case .slipped: BC.coral
        case .skipped: BC.faint
        case .pending: current ? Color.white : Color.white.opacity(0.14)
        }
    }

    // MARK: Playing

    private var playing: some View {
        BoardLayout(reserve: 230, minBoard: 260) { _ in
            lineHeader.padding(.horizontal, BC.side).padding(.bottom, 10)
        } board: { size in
            ZStack {
                BoardView(state: session.board, size: size)
                    .id(session.current)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .move(edge: .leading).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity)
            .clipped()
        } panel: {
            coachCard.padding(.horizontal, BC.side).padding(.top, 14)
            Spacer(minLength: 8)
            actions.padding(.horizontal, BC.side).padding(.bottom, 8)
        }
    }

    private var lineHeader: some View {
        HStack(spacing: 8) {
            if let line = session.line {
                Circle().fill(line.rep.color == .white ? Color.white : Color(hex: 0x3A3A40))
                    .overlay(Circle().stroke(Color.white.opacity(0.5), lineWidth: 1))
                    .frame(width: 10, height: 10)
                Text(line.title).font(.bcBodyStrong).foregroundStyle(BC.ink).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 6)
                if let v = session.viewPly {
                    Text(v == 0 ? "Start" : "Move \(v)")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(BC.mute)
                } else if line.learnCount > 0 {
                    Text(session.pass == .recall ? "From memory" : "\(line.learnCount) new")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(BC.blue)
                }
            }
        }
        .frame(height: 22)
        .id(session.current)
    }

    private var toneColour: Color {
        switch session.tone {
        case .neutral: BC.ink
        case .right, .done: BC.mint
        case .wrong: BC.coral
        case .learn: BC.blue
        }
    }

    private var coachCard: some View {
        CardBox(padding: 16) {
            if session.lineDone { doneContent } else { coachContent }
        }
        .overlay(alignment: .leading) {
            Capsule().fill(toneColour.opacity(session.tone == .neutral || session.lineDone ? 0 : 0.9))
                .frame(width: 3, height: 40).padding(.leading, 1)
        }
    }

    /// The line is done: what happened, then Analyse and Next.
    private var doneContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(session.headline)
                    .font(.bcCardTitle).foregroundStyle(toneColour)
                    .lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength: 6)
                if let tag = session.tag { Tag(text: tag.text, colour: tag.colour) }
            }
            HStack(spacing: 10) {
                Button {
                    analyse()
                } label: {
                    Label("Analyse", systemImage: "cpu")
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(BC.ink)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(BC.raised, in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
                }
                .buttonStyle(PressStyle())
                Button {
                    Feel.tap()
                    session.nextLine()
                } label: {
                    HStack(spacing: 6) {
                        Text(session.isLastLine ? "Finish" : "Next line")
                        Image(systemName: session.isLastLine ? "checkmark" : "arrow.right")
                    }
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(Color.white, in: Capsule())
                }
                .buttonStyle(PressStyle())
            }
        }
        .frame(height: 78, alignment: .top)
    }

    private var coachContent: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(session.headline)
                        .font(.bcCardTitle).foregroundStyle(toneColour)
                        .lineLimit(1).minimumScaleFactor(0.75)
                    Spacer(minLength: 6)
                    if let tag = session.tag { Tag(text: tag.text, colour: tag.colour) }
                }
                Text(session.detail)
                    .font(.bcBody).foregroundStyle(BC.mute)
                    .lineLimit(3).minimumScaleFactor(0.9)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(height: 78, alignment: .top)
    }

    /// Previous line · back a move · forward a move · Why? · next line.
    private var actions: some View {
        HStack(spacing: 6) {
            control("backward.end.fill", "Previous line", enabled: session.current > 0) { session.previousLine() }
            control("chevron.left", "Back a move", enabled: session.canStepBack) { session.stepBack() }
            control("chevron.right", "Forward a move", enabled: session.canStepForward) { session.stepForward() }
            Spacer(minLength: 2)
            Button {
                Feel.tick()
                openWhy()
            } label: {
                Text("Why?").fixedSize()
            }
            .buttonStyle(PillButton())
            .disabled(session.whyNode == nil)
            .opacity(session.whyNode == nil ? 0.4 : 1)
            Button { analyse() } label: { Text("Analyse").fixedSize() }
                .buttonStyle(PillButton())
                .disabled(session.analysisStart == nil)
            control("forward.end.fill", session.isLastLine ? "Finish" : "Next line", enabled: true) { session.nextLine() }
        }
    }

    /// The board at the position on screen. While your move is pending, looking costs the same as "Why?".
    private func analyse() {
        Feel.tick()
        if session.waiting && session.viewPly == nil { _ = session.notePeek() }
        if let start = session.analysisStart { app.open(.board(start)) }
    }

    private func control(_ icon: String, _ label: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // 42 round; a little smaller on the narrowest phones so the words beside them fit.
            Image(systemName: icon).font(.system(size: 15, weight: .bold)).foregroundStyle(BC.ink)
                .frame(minWidth: 34, maxWidth: 42, minHeight: 42, maxHeight: 42)
                .background(BC.card, in: Circle())
                .overlay(Circle().stroke(BC.line, lineWidth: 1))
        }
        .buttonStyle(PressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .accessibilityLabel(label)
    }

    private func openWhy() {
        guard let line = session.line, let n = session.whyNode else { return }
        let fen = session.waiting ? session.currentFEN : n.fenBefore
        let note = session.notePeek()
        why = WhyTarget(rep: line.rep, node: n, fen: fen, peekNote: note)
    }

    // MARK: Empty

    /// Nothing in this mode right now: never "come back later", always something to do now.
    private var emptyState: some View {
        VStack(spacing: 12) {
            if session.limitReached {
                EmptyCard(title: Allowance.newLines.headline, message: "Revise what you know, or go unlimited with Pro.")
                BlockButton(title: "Go unlimited", systemImage: "sparkles") { Pro.shared.paywall = .newLines }
            } else {
                EmptyCard(title: "Nothing due here", message: "Learn new moves or test yourself on what you know.")
            }
            if session.canLearnMore && !session.limitReached {
                BlockButton(title: "Learn new moves", systemImage: "sparkles") {
                    session.build(mode: .learn); session.begin()
                }
            }
            SecondaryButton(title: "Revise what I know", systemImage: "shuffle") {
                session.build(mode: .revise); session.begin()
            }
            Spacer()
        }
        .padding(.horizontal, BC.side)
        .padding(.top, BC.gap)
        .readableColumn()
    }
}

// MARK: - Summary

private struct PracticeSummary: View {
    @ObservedObject var session: PracticeSession
    @EnvironmentObject var progress: ProgressStore
    let done: () -> Void
    @State private var shown: [String: Double] = [:]
    @State private var count = 0

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: BC.gap) {
                    VStack(alignment: .leading, spacing: 4) {
                        LabelText("Session done", colour: BC.mint)
                        Text("\(count)")
                            .font(.system(size: 72, weight: .bold).monospacedDigit())
                            .tracking(-1.5)
                            .foregroundStyle(BC.ink)
                            .contentTransition(.numericText())
                        Text(session.rightFirst == 1 ? "move right first try" : "moves right first try")
                            .font(.bcBody).foregroundStyle(BC.mute)
                    }
                    .padding(.top, 8)
                    .arrive(0)

                    HStack(spacing: 12) {
                        StatCard(label: "First try", value: session.tries == 0 ? "—" : OpeningText.percent(Double(session.rightFirst) / Double(session.tries)),
                                 context: session.tries == 0 ? "nothing graded" : "\(session.rightFirst) of \(session.tries)",
                                 colour: BC.ink)
                        StatCard(label: "Learned", value: "\(session.newlyLearned)",
                                 context: session.newlyLearned == 1 ? "new move" : "new moves",
                                 colour: session.newlyLearned > 0 ? BC.mint : BC.ink)
                    }
                    .arrive(1)

                    CardBox {
                        VStack(alignment: .leading, spacing: 14) {
                            LabelText("Coverage")
                            ForEach(session.reps, id: \.id) { rep in
                                coverageRow(rep)
                            }
                        }
                    }
                    .arrive(2)

                }
                .padding(.horizontal, BC.side)
                .padding(.top, 12)
                .padding(.bottom, 24)
                .readableColumn()
            }
            .scrollIndicators(.hidden)
            VStack(spacing: 6) {
                BlockButton(title: "Keep going", systemImage: "play.fill") { session.keepGoing() }
                QuietButton(title: "Done for now", action: done)
            }
            .padding(.horizontal, BC.side)
            .padding(.bottom, 8)
            .readableColumn()
        }
        .onAppear {
            shown = session.coverageBefore
            withAnimation(BC.curve(0.7).delay(0.2)) { count = session.rightFirst }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                withAnimation(BC.curve(1.2)) {
                    for rep in session.reps { shown[rep.id] = progress.coverage(rep) }
                }
            }
        }
    }

    private func coverageRow(_ rep: Repertoire) -> some View {
        let before = session.coverageBefore[rep.id] ?? 0
        let now = progress.coverage(rep)
        let value = shown[rep.id] ?? before
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(rep.color == .white ? "White" : "Black").font(.bcRowTitle).foregroundStyle(BC.ink)
                Spacer()
                Text("\(OpeningText.percent(before)) → \(OpeningText.percent(now))")
                    .font(.system(size: 15, weight: .bold).monospacedDigit())
                    .foregroundStyle(now > before + 0.0005 ? BC.mint : BC.mute)
            }
            ProgressBar(value: value, colour: BC.mint)
        }
    }
}

// MARK: - Why

/// The note for a move and Stockfish's line from the position, played out on its own board.
private struct WhySheet: View {
    let rep: Repertoire
    let node: RepNode
    let fen: String
    let peekNote: String?
    @StateObject private var board = BoardState()
    @StateObject private var line = LinePlayer()
    @State private var shown: EngineLine?          // the eval of the line actually played out
    @State private var failed = false
    @State private var search: Task<Void, Never>?

    private static let owner = "why"

    var body: some View {
        SheetChrome(title: "Why \(node.numbered)?", colour: BC.blue) {
            VStack(alignment: .leading, spacing: 14) {
                Text(node.whyLine).font(.bcBody).foregroundStyle(BC.ink).fixedSize(horizontal: false, vertical: true)
                if let peekNote {
                    Text(peekNote).font(.bcCaption).foregroundStyle(BC.faint)
                }
                // As wide as the sheet on a phone; on an iPad's form sheet, small enough to leave room for the line.
                GeometryReader { g in
                    BoardView(state: board, size: g.size.width)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity)
                .layoutPriority(1)
                Group {
                    if line.isActive {
                        LineStrip(player: line)
                    } else {
                        Text(failed ? "Stockfish couldn't look at this one." : "Stockfish is thinking…")
                            .font(.bcBody).foregroundStyle(BC.mute)
                            .frame(height: 30, alignment: .leading)
                    }
                }
                if let shown {
                    HStack(spacing: 8) {
                        Tag(text: Eval.text(cp: shown.cp, mate: shown.mate), colour: BC.violet)
                        Text("Stockfish's line, depth \(shown.depth)").font(.bcCaption).foregroundStyle(BC.mute)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .onAppear {
            board.flipped = rep.color == .black
            board.set(fen: fen, lastMove: nil, animated: false)
            board.arrows = [BoardArrow(from: node.from, to: node.to, colour: BC.arrow, opacity: 0.85)]
            startSearch()
        }
        .onDisappear {
            search?.cancel()
            search = nil
            line.clear()
            Task { await EngineService.shared.stop(owner: Self.owner) }
        }
    }

    private func startSearch() {
        guard search == nil, !line.isActive else { return }
        search = Task { @MainActor in
            let lines = await EngineService.shared.analyse(fen: fen, depth: 16, multipv: 1, owner: Self.owner)
            guard !Task.isCancelled else { return }
            guard let l = lines.first, !l.pv.isEmpty else { failed = true; return }
            // Start with your repertoire move, then Stockfish's best play after it.
            var pv = l.pv
            var eval: EngineLine? = l
            if l.best != node.uci, let p = Chess.play(node.uci, on: fen) {
                let after = await EngineService.shared.analyse(fen: p.fenAfter, depth: 14, multipv: 1, owner: Self.owner)
                guard !Task.isCancelled else { return }
                pv = [p.uci] + (after.first?.pv ?? [])
                // The tag rates the line that's played: the position after your move.
                eval = after.first
            }
            shown = eval
            line.play(pv, from: fen, on: board, colour: BC.violet, limit: 9)
        }
    }
}
