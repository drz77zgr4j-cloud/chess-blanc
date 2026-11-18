import SwiftUI

/// First launch: a welcome with a live board, your name, your games (chess.com or Lichess, optional), done.
/// Everything can be skipped; nothing here is needed to use the app.
struct OnboardingView: View {
    @EnvironmentObject var progress: ProgressStore
    @EnvironmentObject var store: GameStore
    let finish: () -> Void

    enum Step: Int, CaseIterable { case welcome, name, games, ready }
    enum Service: String, CaseIterable { case chessCom = "chess.com", lichess = "Lichess" }

    @State private var step: Step = .welcome
    @State private var name = ""
    @State private var service: Service = .chessCom
    @State private var username = ""
    @State private var checking = false
    @State private var found: String?
    @State private var foundName: String?
    @State private var error: String?
    @State private var linked: (Service, String)?
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            BC.bg.ignoresSafeArea()
            Spotlight(colour: glow, strength: 0.42).ignoresSafeArea()
                .animation(BC.curve(0.8), value: step)
            VStack(spacing: 0) {
                topBar
                ZStack {
                    switch step {
                    case .welcome: welcome.transition(page)
                    case .name: namePage.transition(page)
                    case .games: gamesPage.transition(page)
                    case .ready: readyPage.transition(page)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .readableColumn()
        }
        .preferredColorScheme(.dark)
    }

    private var glow: Color {
        switch step {
        case .welcome: BC.blue
        case .name: BC.amber
        case .games: BC.mint
        case .ready: BC.blue
        }
    }

    private var page: AnyTransition {
        .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity))
    }

    private func go(_ s: Step) {
        focused = false
        Feel.tick()
        withAnimation(BC.curve(0.5)) { step = s }
    }

    // MARK: Top bar: progress dots and Skip

    private var topBar: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { s in
                    Capsule().fill(s.rawValue <= step.rawValue ? BC.ink : BC.ink.opacity(0.18))
                        .frame(width: s == step ? 22 : 7, height: 7)
                }
            }
            .animation(BC.curve(0.4), value: step)
            Spacer()
            if step != .ready {
                Button("Skip") { complete() }
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(BC.mute)
                    .accessibilityHint("Starts the app without setting anything up")
            }
        }
        .frame(height: 44)
        .padding(.horizontal, BC.side).padding(.top, 8)
    }

    // MARK: 1. Welcome

    private var welcome: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                Spacer(minLength: 8)
                LiveBoard(size: min(geo.size.width - 96, geo.size.height * 0.33, 340))
                Spacer(minLength: 20)
                VStack(spacing: 10) {
                    Text("Chess Blanc").font(.system(size: 40, weight: .bold)).tracking(-1).foregroundStyle(BC.ink)
                    Text("The modern way to learn chess.")
                        .font(.system(size: 18, weight: .medium)).foregroundStyle(BC.mute)
                }
                .multilineTextAlignment(.center)
                Spacer(minLength: 18)
                VStack(alignment: .leading, spacing: 14) {
                    feature("book.closed.fill", BC.violet, "Openings that stick", "Every line and every reply, learned for good.")
                    feature("scope", BC.mint, "Every game reviewed", "Your mistakes, ranked, turned into drills.")
                    feature("shield.lefthalf.filled", BC.coral, "Stop hanging pieces", "A check before every move, until it's habit.")
                }
                .padding(.horizontal, 6)
                Spacer(minLength: 20)
                BlockButton(title: "Get started", systemImage: "arrow.right") { go(.name) }
                    .padding(.bottom, 16)
            }
            .padding(.horizontal, BC.side)
        }
    }

    private func feature(_ icon: String, _ colour: Color, _ title: String, _ line: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(colour)
                .frame(width: 42, height: 42)
                .background(colour.opacity(0.14), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(BC.ink)
                Text(line).font(.system(size: 14)).foregroundStyle(BC.mute).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: 2. Name

    private var namePage: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 20)
            Image(systemName: "hand.wave.fill").font(.system(size: 30)).foregroundStyle(BC.amber)
                .frame(width: 64, height: 64)
                .background(BC.amber.opacity(0.14), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Text("What should we\ncall you?").font(.system(size: 34, weight: .bold)).tracking(-0.6)
                .foregroundStyle(BC.ink).padding(.top, 22)
            Text("Just your first name. It stays on this device.")
                .font(.bcBody).foregroundStyle(BC.mute).padding(.top, 8)
            field(text: $name, placeholder: "Your name", icon: "person.fill", content: .givenName)
                .padding(.top, 26)
                .onSubmit { saveName(); go(.games) }
            Spacer()
            BlockButton(title: "Continue", systemImage: "arrow.right") { saveName(); go(.games) }
            QuietButton(title: "Not now") { go(.games) }.frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .padding(.horizontal, BC.side)
        .onAppear { name = progress.settings.name; DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { focused = true } }
    }

    private func saveName() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { progress.settings.name = String(n.prefix(30)) }
    }

    // MARK: 3. Your games

    private var gamesPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 20)
            Image(systemName: "link").font(.system(size: 28, weight: .semibold)).foregroundStyle(BC.mint)
                .frame(width: 64, height: 64)
                .background(BC.mint.opacity(0.14), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Text("Bring your games").font(.system(size: 34, weight: .bold)).tracking(-0.6)
                .foregroundStyle(BC.ink).padding(.top, 22)
            Text("Every game you play gets reviewed, and your mistakes become training. Just your username — no password, nothing is ever posted.")
                .font(.bcBody).foregroundStyle(BC.mute).padding(.top, 8).fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                ForEach(Service.allCases, id: \.self) { s in
                    Button {
                        Feel.tick()
                        withAnimation(BC.curve(0.3)) { service = s; found = nil; error = nil }
                    } label: {
                        Text(s.rawValue).font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(service == s ? Color.black : BC.mute)
                            .frame(maxWidth: .infinity).frame(height: 40)
                            .background(service == s ? BC.ink : .clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(BC.card, in: Capsule())
            .overlay(Capsule().stroke(BC.line, lineWidth: 1))
            .padding(.top, 24)

            field(text: $username, placeholder: "\(service.rawValue) username", icon: "at", content: .username)
                .padding(.top, 12)
                .onChange(of: username) { _, _ in found = nil; error = nil }
                .onSubmit { Task { await check() } }

            if let found {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 22)).foregroundStyle(BC.mint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(foundName ?? found).font(.bcBodyStrong).foregroundStyle(BC.ink)
                        Text("Found on \(service.rawValue)").font(.bcCaption).foregroundStyle(BC.mute)
                    }
                    Spacer()
                }
                .padding(14)
                .background(BC.mint.opacity(0.1), in: RoundedRectangle(cornerRadius: BC.rRow, style: .continuous))
                .padding(.top, 12)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
            if let error {
                Text(error).font(.bcCaption).foregroundStyle(BC.coral).padding(.top, 10)
            }
            Spacer()
            if found != nil {
                BlockButton(title: "Link and continue", systemImage: "arrow.right") { link() }
            } else {
                BlockButton(title: checking ? "Looking…" : "Find my games", systemImage: "magnifyingglass",
                            enabled: !checking && Net.username(username) != nil) {
                    Task { await check() }
                }
            }
            QuietButton(title: "I'll do this later") { go(.ready) }.frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .padding(.horizontal, BC.side)
    }

    private func check() async {
        guard let n = Net.username(username), !checking else {
            error = "Usernames are letters, numbers, - and _."
            return
        }
        focused = false
        checking = true
        error = nil
        defer { checking = false }
        do {
            switch service {
            case .chessCom:
                let p = try await ChessCom.profile(n)
                withAnimation(BC.curve(0.35)) { found = p.username; foundName = p.name.flatMap { $0.isEmpty ? nil : $0 } }
            case .lichess:
                if let u = try await Lichess.user(n) {
                    withAnimation(BC.curve(0.35)) { found = u; foundName = nil }
                } else { error = "No Lichess player with that username." }
            }
            if found != nil { Feel.success() }
        } catch let e as ChessCom.Failure {
            error = service == .chessCom ? (e.errorDescription ?? "Couldn't reach chess.com.") : "Couldn't reach Lichess. Check your connection."
        } catch {
            self.error = "Couldn't reach \(service.rawValue). Check your connection and try again."
        }
    }

    private func link() {
        guard let found else { return }
        linked = (service, found)
        switch service {
        case .chessCom: progress.settings.chessComUser = found
        case .lichess:
            progress.settings.lichessUser = found
            store.lichessUser = found
        }
        let s = progress.settings
        Task { await store.sync(user: s.chessComUser, months: s.historyMonths, autoReview: s.autoReview) }
        Feel.gained()
        go(.ready)
    }

    // MARK: 4. Ready

    private var readyPage: some View {
        VStack(spacing: 0) {
            Spacer()
            ReadyMark()
            Text(progress.settings.name.isEmpty ? "You're all set" : "You're all set, \(progress.settings.name)")
                .font(.system(size: 32, weight: .bold)).tracking(-0.6).foregroundStyle(BC.ink)
                .multilineTextAlignment(.center).padding(.top, 28)
            Text(readyLine).font(.bcBody).foregroundStyle(BC.mute)
                .multilineTextAlignment(.center).padding(.top, 10).padding(.horizontal, 20)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            BlockButton(title: "Start playing", systemImage: "play.fill") { complete() }
                .padding(.bottom, 16)
        }
        .padding(.horizontal, BC.side)
        .onAppear { Feel.complete() }
    }

    private var readyLine: String {
        if let (s, u) = linked {
            return "\(u)'s \(s.rawValue) games are downloading now and get reviewed in the background. Start with today's practice."
        }
        return "Start with today's practice: your first opening lines are waiting. You can link chess.com or Lichess any time on the You page."
    }

    private func complete() {
        focused = false
        saveName()
        UserDefaults.standard.set(true, forKey: OnboardingView.doneKey)
        finish()
    }

    static let doneKey = "bc.onboarded"

    /// Show it on a first launch only (people who already linked an account or set a name have been here).
    @MainActor static func needed(_ settings: AppSettings) -> Bool {
        !UserDefaults.standard.bool(forKey: doneKey) && !settings.linked && settings.name.isEmpty
    }

    // MARK: Pieces

    private func field(text: Binding<String>, placeholder: String, icon: String, content: UITextContentType) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(BC.mute).frame(width: 20)
            TextField("", text: text, prompt: Text(placeholder).foregroundStyle(BC.faint))
                .font(.system(size: 18, weight: .semibold)).foregroundStyle(BC.ink)
                .textContentType(content)
                .autocorrectionDisabled()
                .textInputAutocapitalization(content == .username ? .never : .words)
                .submitLabel(.continue)
                .focused($focused)
        }
        .padding(.horizontal, 16).frame(height: 58)
        .background(BC.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(focused ? BC.ink.opacity(0.35) : BC.line, lineWidth: 1))
        .animation(BC.curve(0.25), value: focused)
    }
}

/// A board playing the Italian Game on its own, tilted a little, on a glow.
private struct LiveBoard: View {
    let size: CGFloat
    @State private var fen = Chess.startFEN
    @State private var last: [String] = []
    private static let moves = ["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "f8c5", "c2c3", "g8f6", "d2d4", "e5d4", "c3d4", "c5b4", "b1c3", "f6e4", "e1g1"]

    var body: some View {
        MiniBoard(fen: fen, size: size, highlight: last, radius: size * 0.06)
            .shadow(color: BC.blue.opacity(0.45), radius: 40, y: 18)
            .rotation3DEffect(.degrees(14), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
            .animation(.easeInOut(duration: 0.35), value: fen)
            .task {
                while !Task.isCancelled {
                    var f = Chess.startFEN
                    fen = f; last = []
                    try? await Task.sleep(for: .seconds(1.2))
                    for m in Self.moves {
                        guard !Task.isCancelled, let p = Chess.play(m, on: f) else { break }
                        f = p.fenAfter
                        fen = f; last = [p.from, p.to]
                        try? await Task.sleep(for: .seconds(1.1))
                    }
                    try? await Task.sleep(for: .seconds(2.2))
                }
            }
            .accessibilityHidden(true)
    }
}

/// The finishing tick: a ring that draws itself, then the check.
private struct ReadyMark: View {
    @State private var drawn = false
    var body: some View {
        ZStack {
            Circle().fill(BC.blue.opacity(0.12)).frame(width: 120, height: 120)
            Circle().trim(from: 0, to: drawn ? 1 : 0)
                .stroke(BC.blue, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90)).frame(width: 104, height: 104)
            Image(systemName: "checkmark").font(.system(size: 44, weight: .bold)).foregroundStyle(BC.ink)
                .scaleEffect(drawn ? 1 : 0.4).opacity(drawn ? 1 : 0)
        }
        .shadow(color: BC.blue.opacity(0.5), radius: 30)
        .onAppear { withAnimation(.easeOut(duration: 0.7)) { drawn = true } }
    }
}
