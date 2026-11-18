import SwiftUI

// MARK: - Engine / verdict area

/// The fixed-height area above the board. Its height never depends on what it shows, so the board never moves.
struct EnginePanel: View {
    @ObservedObject var model: BoardModel

    var body: some View {
        GeometryReader { geo in
            content(height: geo.size.height)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .clipped()
        .animation(BC.curve(0.24), value: model.checking)
    }

    @ViewBuilder
    private func content(height: CGFloat) -> some View {
        if model.mode == .bot, let w = model.guardWarning {
            NoteRow(icon: "exclamationmark.triangle.fill", colour: BC.coral, title: "Wait — check that move",
                    detail: w.text + " What can the bot do after it?") {
                HStack(spacing: 8) {
                    Button("Think again") { model.thinkAgain() }.buttonStyle(PillButton(filled: true))
                    Button("Play it anyway") { Feel.tick(); model.playAnyway() }.buttonStyle(PillButton())
                }
            }
        } else if model.mode == .bot {
            botPanel
        } else if model.playingLine {
            NoteRow(icon: "play.circle.fill", colour: BC.mint, title: "Playing the line",
                    detail: "Step back through it any time with ‹.")
        } else if let h = model.hint {
            hintPanel(h)
        } else if let r = model.retrying {
            NoteRow(icon: "arrow.counterclockwise.circle.fill", colour: r.cls.colour, title: "Try again",
                    detail: "Find a better move than \(r.ply.san).")
        } else if model.lineShown {
            NoteRow(icon: "checkmark.circle.fill", colour: BC.mint, title: "That's Stockfish's line",
                    detail: "Use ‹ to step back through it, or keep playing.")
        } else if let o = model.outcomeText {
            NoteRow(icon: "flag.checkered", colour: BC.ink, title: o, detail: "Go back to try something else.")
        } else {
            switch model.engineMode {
            case .lines: linesPanel(height: height)
            case .judge: judgePanel
            case .off:
                NoteRow(icon: "power", colour: BC.mute, title: "The engine is off", detail: "Move freely. No lines, no marks.") {
                    Button("Turn on") { Feel.tick(); model.setEngineMode(.lines) }.buttonStyle(PillButton())
                }
            }
        }
    }

    // MARK: Lines

    private func linesPanel(height: CGFloat) -> some View {
        let rowH: CGFloat = 24
        let fit = max(1, Int((height - 28) / rowH))
        let count = min(max(1, model.settings.engineLines), fit)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                EvalBar(cp: model.bar.cp, mate: model.bar.mate, height: 20)
                Text(model.depth.map { "depth \($0)" } ?? "thinking")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(BC.faint)
                    .frame(width: 58, alignment: .trailing)
                    .contentTransition(.numericText())
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<count, id: \.self) { i in
                    if i < model.lines.count {
                        LineRow(line: model.lines[i], top: i == 0) { whole in model.playLine(model.lines[i], whole: whole) }
                            .frame(height: rowH)
                    } else {
                        SkeletonRow().frame(height: rowH)
                    }
                }
            }
        }
    }

    // MARK: Judge

    @ViewBuilder
    private var judgePanel: some View {
        if let c = model.checking, c == model.index, c > 0 {
            CheckingRow(san: model.plies[c - 1].san)
        } else if let j = model.currentJudged {
            VerdictView(judged: j,
                        tryAgain: j.cls.isError ? { model.tryAgain(j, at: model.index) } : nil,
                        best: j.wasBest ? nil : { model.showBest(j, at: model.index) },
                        why: j.hasWhy ? { model.showWhy(j, at: model.index) } : nil)
        } else {
            NoteRow(icon: "checkmark.seal", colour: BC.violet, title: "Make a move",
                    detail: "Stockfish marks every move, like a game review. No lines, no hints.")
        }
    }

    private func hintPanel(_ h: BoardModel.BestHint) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ClassBadge(cls: .best, size: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text("Best was \(h.san)").font(.system(size: 17, weight: .bold)).foregroundStyle(BC.mint)
                    .lineLimit(1).minimumScaleFactor(0.8)
                FadingText(text: Chess.sanLine(h.pv, from: h.fen, limit: 8).joined(separator: " "))
                HStack(spacing: 8) {
                    Button { model.playHintLine() } label: { Label("Play the line", systemImage: "play.fill") }
                        .buttonStyle(PillButton(filled: true))
                }
                .padding(.top, 5)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Bot

    @ViewBuilder
    private var botPanel: some View {
        if let j = model.showingBest {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ClassBadge(cls: model.showingWhy ? j.cls : .best, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.showingWhy ? "Why \(j.ply.san) works" : "Best was \(j.bestSAN ?? "")")
                            .font(.system(size: 17, weight: .bold)).foregroundStyle(model.showingWhy ? j.cls.colour : BC.mint)
                            .lineLimit(1).minimumScaleFactor(0.8)
                        Text(model.showingWhy ? "Stockfish's line" : "Instead of \(j.ply.san)").font(.bcCaption).foregroundStyle(BC.mute).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button("Back to game") { Feel.tick(); model.closeBotBest() }.buttonStyle(PillButton(filled: true))
                }
                LineStrip(player: model.player)
            }
        } else if let r = model.result {
            NoteRow(icon: r.kind == .win ? "trophy.fill" : r.kind == .loss ? "flag.fill" : "equal.circle.fill",
                    colour: r.kind == .win ? BC.mint : r.kind == .loss ? BC.coral : BC.ink,
                    title: r.kind == .win ? "You won" : r.kind == .loss ? "You lost" : "Draw",
                    detail: r.reason + ".")
        } else if model.botStuck {
            NoteRow(icon: "exclamationmark.triangle.fill", colour: BC.coral, title: "Couldn't think of a move",
                    detail: "Stockfish didn't answer. Ask the bot again.") {
                Button { Feel.tick(); model.retryBot() } label: { Label("Retry", systemImage: "arrow.clockwise") }
                    .buttonStyle(PillButton(filled: true))
            }
        } else if let c = model.checking, c > 0, c <= model.plies.count {
            CheckingRow(san: model.plies[c - 1].san)
        } else if let v = model.lastBotVerdict {
            VerdictView(judged: v.judged, tryAgain: nil, best: v.judged.wasBest ? nil : { model.showBotBest() },
                        why: v.judged.hasWhy ? { model.showBotWhy() } : nil)
        } else if let g = model.game {
            NoteRow(icon: "cpu", colour: BC.violet,
                    title: model.sideToMove == g.side ? "Your move" : "The bot moves first",
                    detail: "Every move you play gets marked. If it wasn't the best, you'll see what was.")
        }
    }
}

// MARK: - Rows

/// "Nxe5 is a blunder" with the coach's one line and the actions that follow.
struct VerdictView: View {
    let judged: BoardModel.Judged
    let tryAgain: (() -> Void)?
    let best: (() -> Void)?
    var why: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ClassBadge(cls: judged.cls, size: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(judged.headline)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(judged.cls.colour)
                    .lineLimit(1).minimumScaleFactor(0.75)
                Text(judged.detail)
                    .font(.bcCaption).foregroundStyle(BC.mute)
                    .lineLimit(2).minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
                if tryAgain != nil || best != nil || why != nil {
                    HStack(spacing: 8) {
                        if let why {
                            Button { Feel.tick(); why() } label: { Label("Show why", systemImage: "play.fill") }
                                .buttonStyle(PillButton(filled: true))
                        }
                        if let tryAgain {
                            Button { Feel.tick(); tryAgain() } label: { Label("Try again", systemImage: "arrow.counterclockwise") }
                                .buttonStyle(PillButton(filled: true))
                        }
                        if let best {
                            Button { Feel.tick(); best() } label: { Label("Best move", systemImage: "sparkles") }
                                .buttonStyle(PillButton(filled: tryAgain == nil && why == nil))
                        }
                    }
                    .padding(.top, 5)
                }
            }
            Spacer(minLength: 0)
        }
        .transition(.opacity)
        .id(judged.ply.fenAfter + judged.cls.rawValue)
    }
}

struct NoteRow<Action: View>: View {
    let icon: String
    let colour: Color
    let title: String
    let detail: String
    @ViewBuilder var action: Action

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 20, weight: .semibold)).foregroundStyle(colour)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 17, weight: .bold)).foregroundStyle(BC.ink).lineLimit(1).minimumScaleFactor(0.8)
                Text(detail).font(.bcCaption).foregroundStyle(BC.mute).lineLimit(2).minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
                action.padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
    }
}

extension NoteRow where Action == EmptyView {
    init(icon: String, colour: Color, title: String, detail: String) {
        self.icon = icon; self.colour = colour; self.title = title; self.detail = detail; self.action = EmptyView()
    }
}

struct CheckingRow: View {
    let san: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(BC.raised2).frame(width: 26, height: 26)
                .overlay(PulseDot(colour: BC.violet))
            VStack(alignment: .leading, spacing: 3) {
                Text("Checking \(san)…").font(.system(size: 17, weight: .bold)).foregroundStyle(BC.ink).lineLimit(1)
                Text("Stockfish is looking at it.").font(.bcCaption).foregroundStyle(BC.mute)
            }
            Spacer(minLength: 0)
        }
    }
}

/// One engine line: the score, then the moves fading out to the right. Tap plays the first move; hold plays it all.
struct LineRow: View {
    let line: BoardModel.ShownLine
    let top: Bool
    let play: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(line.eval)
                .font(.system(size: 12, weight: .heavy).monospacedDigit())
                .foregroundStyle(line.eval.hasPrefix("-") ? BC.ink : .black)
                .frame(width: 50, height: 20)
                .background(line.eval.hasPrefix("-") ? Color(hex: 0x403D39) : Color(hex: 0xF0F0F0),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            FadingText(text: line.text, size: 14, colour: top ? BC.ink : Color(hex: 0xC9C9CE))
        }
        .contentShape(Rectangle())
        .gesture(
            LongPressGesture(minimumDuration: 0.45)
                .onEnded { _ in Feel.lift(); play(true) }
                .exclusively(before: TapGesture().onEnded { Feel.tick(); play(false) })
        )
        .accessibilityElement(children: .combine)
        .accessibilityHint("Tap to play the first move. Hold to play the whole line.")
        .accessibilityAddTraits(.isButton)
    }
}

/// One line of text that fades out instead of being cut off with an ellipsis.
struct FadingText: View {
    let text: String
    var size: CGFloat = 13
    var colour: Color = BC.mute

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: size * 1.4)
            .overlay(alignment: .leading) {
                Text(text)
                    .font(.system(size: size))
                    .foregroundStyle(colour)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .mask(
                LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.82),
                                       .init(color: .clear, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
            )
            .clipped()
    }
}

struct SkeletonRow: View {
    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(BC.raised).frame(width: 50, height: 20)
            Capsule().fill(BC.raised).frame(height: 10).frame(maxWidth: 190)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Move strip

/// Every move in one sideways row that follows the current move. Tap a move to go to it.
struct MoveStrip: View {
    @ObservedObject var model: BoardModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(Array(model.plies.enumerated()), id: \.offset) { i, p in
                        let before = model.fen(at: i)
                        let white = Chess.sideToMove(before) == .white
                        if white || i == 0 {
                            Text(white ? "\(Chess.moveNumber(before))." : "\(Chess.moveNumber(before))…")
                                .font(.system(size: 13, weight: .medium).monospacedDigit())
                                .foregroundStyle(BC.faint)
                                .padding(.leading, i == 0 ? 0 : 8)
                        }
                        cell(i, p).id(i)
                    }
                }
                .padding(.horizontal, BC.side)
                .frame(height: 40)
            }
            .scrollIndicators(.hidden)
            .onChange(of: model.index) { _, i in
                withAnimation(.easeOut(duration: 0.22)) { proxy.scrollTo(max(0, i - 1), anchor: .center) }
            }
            .onChange(of: model.plies.count) { _, _ in
                withAnimation(.easeOut(duration: 0.22)) { proxy.scrollTo(max(0, model.index - 1), anchor: .center) }
            }
            .onAppear { proxy.scrollTo(max(0, model.index - 1), anchor: .center) }
        }
        .frame(height: 40)
    }

    private func cell(_ i: Int, _ p: Ply) -> some View {
        let on = model.index == i + 1
        let mark = model.judged[i + 1]?.cls
        return Button {
            guard model.mode == .analyse else { return }
            Feel.tick()
            model.go(to: i + 1)
        } label: {
            HStack(spacing: 4) {
                if let mark { Circle().fill(mark.colour).frame(width: 7, height: 7) }
                Text(p.san)
                    .font(.system(size: 15, weight: on ? .bold : .semibold))
                    .foregroundStyle(on ? .black : (i < model.index ? BC.ink : BC.mute))
            }
            .padding(.horizontal, 9).frame(height: 30)
            .background(on ? Color.white : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
