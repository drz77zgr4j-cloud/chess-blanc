import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var progress: ProgressStore
    @EnvironmentObject var store: GameStore
    @State private var confirmReset = false
    @State private var toast: Toast?
    @ObservedObject private var pro = Pro.shared

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: "You")
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    profile
                    proCard
                    SectionBox(title: "Sound & haptics") {
                        RowGroup {
                            toggle("Sounds", \.sound)
                            toggle("Haptics", \.haptics)
                        }
                    }
                    SectionBox(title: "Your games") {
                        RowGroup {
                            Button { app.open(.link) } label: {
                                Row(title: "Account", value: progress.settings.chessComUser.isEmpty ? "Not linked" : progress.settings.chessComUser,
                                    valueColour: progress.settings.chessComUser.isEmpty ? BC.coral : BC.mute) {
                                    IconTile(systemImage: "person.crop.circle", colour: BC.mint, size: 32)
                                }
                            }
                            .buttonStyle(.plain)
                            Button { app.open(.linkLichess) } label: {
                                Row(title: "Lichess", value: progress.settings.lichessUser.isEmpty ? "Not linked" : progress.settings.lichessUser,
                                    valueColour: BC.mute) {
                                    IconTile(systemImage: "person.crop.circle", colour: BC.blue, size: 32)
                                }
                            }
                            .buttonStyle(.plain)
                            historyRow
                            toggle("Review new games automatically", \.autoReview)
                        }
                    }
                    SectionBox(title: "Board") {
                        VStack(alignment: .leading, spacing: 12) {
                            themePicker
                            piecePicker
                        RowGroup {
                            toggle("Coordinates", \.coordinates)
                            toggle("Move arrows", \.moveArrows)
                            toggle("Blunder guard vs the bot", \.blunderGuard)
                        }
                        }
                    }
                    SectionBox(title: "Training") {
                        RowGroup {
                            stepper("New moves per day", sub: "Fresh moves in each session", \.newMovesPerDay, 0...30)
                        }
                    }
                    SectionBox(title: "Engine") {
                        RowGroup {
                            stepper("Depth", sub: "Stronger, but slower", \.engineDepth, 10...26)
                            stepper("Lines", sub: "Shown on the analysis board", \.engineLines, 1...5)
                        }
                    }
                    SectionBox(title: "Data") {
                        RowGroup {
                            Button { Feel.tick(); confirmReset = true } label: {
                                HStack {
                                    Text("Reset training progress").font(.bcRowTitle).foregroundStyle(BC.coral)
                                    Spacer()
                                }
                                .frame(minHeight: 50)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    SectionBox(title: "About") {
                        CardBox(padding: 16) {
                            VStack(alignment: .leading, spacing: 10) {
                                about("Opening statistics", "Lichess game database: 1.5 million rated club games, 1000 to 1900.")
                                about("Engine", "Stockfish 17. Free software under the GNU GPL v3.")
                                about("Your games", "Read from chess.com's and Lichess's public APIs. Nothing is ever posted.")
                                about("Pieces", PieceSet.all.map { "\($0.name): \($0.credit)" }.joined(separator: "\n"))
                                LegalLinks().padding(.top, 4)
                                Text("Chess Blanc \(version)").font(.bcCaption).foregroundStyle(BC.faint).padding(.top, 2)
                            }
                        }
                    }
                }
                .padding(.horizontal, BC.side).padding(.top, 10).padding(.bottom, 40)
                .readableColumn()
            }
            .scrollIndicators(.hidden)
        }
        .background(Spotlight(colour: app.tab.light))
        .toast($toast)
        .confirmationDialog("Reset training progress?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset progress", role: .destructive) {
                progress.resetTraining()
                Feel.warning()
                toast = Toast(symbol: "arrow.counterclockwise", text: "Training progress reset")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Learned moves, streaks and solved positions are cleared. Your games and reviews stay.")
        }
    }

    /// You, as on Blanc Notes' You page: the picture on its glow, your name (tap to change), your account.
    private var profile: some View {
        VStack(spacing: 10) {
            AvatarTile(image: store.avatar, size: 112)
                .padding(.top, 14).padding(.bottom, 8)
            TextField("", text: Binding(get: { progress.settings.name },
                                        set: { progress.settings.name = String($0.prefix(30)) }),
                      prompt: Text(store.profileName ?? "Your name").foregroundStyle(store.profileName == nil ? BC.faint : BC.ink))
                .font(.system(size: 28, weight: .bold)).tracking(-0.5)
                .foregroundStyle(BC.ink)
                .multilineTextAlignment(.center)
                .submitLabel(.done)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
            if !progress.settings.chessComUser.isEmpty {
                Text(progress.settings.chessComUser).font(.system(size: 15)).foregroundStyle(BC.mute)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Pro: what you have, or the way in. A developer build can preview the free version.
    private var proCard: some View {
        CardBox(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Chess Blanc Pro").font(.bcCardTitle).foregroundStyle(BC.ink)
                    Spacer()
                    Tag(text: pro.isPro ? (pro.subscribed ? "Active" : "Developer") : "Free", colour: pro.isPro ? BC.mint : BC.mute)
                }
                if pro.isPro {
                    Text("No daily limits. Every board and piece set.").font(.bcCaption).foregroundStyle(BC.mute)
                } else {
                    Text("Today: \(pro.left(.newLines)) new lines, \(pro.left(.blunderRounds)) Blunder checks, \(pro.left(.positions)) positions left.")
                        .font(.bcCaption).foregroundStyle(BC.mute).fixedSize(horizontal: false, vertical: true)
                    SecondaryButton(title: "See Pro", systemImage: "sparkles", height: 46) { pro.paywall = .general }
                }
                if pro.developer {
                    Toggle(isOn: $pro.previewFree) {
                        Text("Preview the free version").font(.bcCaption).foregroundStyle(BC.mute)
                    }
                    .tint(BC.blue)
                }
            }
        }
    }

    /// Every board colour, as small boards to tap.
    private var themePicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(Array(BoardTheme.all.enumerated()), id: \.element.id) { i, t in
                    let on = progress.settings.boardTheme == t.id
                    let free = pro.lookFree(i)
                    Button {
                        Feel.tick()
                        guard free else { pro.paywall = .looks; return }
                        withAnimation(BC.curve(0.25)) { progress.settings.boardTheme = t.id }
                    } label: {
                        VStack(spacing: 6) {
                            ThemeSwatch(theme: t)
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(alignment: .topTrailing) { if !free { LockBadge() } }
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(on ? Color.white : Color.white.opacity(0.08), lineWidth: on ? 2.5 : 1))
                            Text(t.name).font(.system(size: 12, weight: on ? .bold : .medium))
                                .foregroundStyle(on ? BC.ink : BC.mute)
                        }
                    }
                    .buttonStyle(PressStyle())
                    .accessibilityLabel("\(t.name) board")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.horizontal, BC.side)
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, -BC.side)
    }

    /// Every piece set: a white and a black knight on your board colours.
    private var piecePicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(Array(PieceSet.all.enumerated()), id: \.element.id) { i, set in
                    let on = progress.settings.pieceSet == set.id
                    let free = pro.lookFree(i)
                    Button {
                        Feel.tick()
                        guard free else { pro.paywall = .looks; return }
                        withAnimation(BC.curve(0.25)) { progress.settings.pieceSet = set.id }
                    } label: {
                        VStack(spacing: 6) {
                            HStack(spacing: 0) {
                                Image(set.image("wK")).resizable().scaledToFit().padding(3)
                                    .frame(width: 34, height: 64).background(BC.lightSquare)
                                Image(set.image("bN")).resizable().scaledToFit().padding(3)
                                    .frame(width: 34, height: 64).background(BC.darkSquare)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(on ? Color.white : Color.white.opacity(0.08), lineWidth: on ? 2.5 : 1))
                            .overlay(alignment: .topTrailing) { if !free { LockBadge() } }
                            Text(set.name).font(.system(size: 12, weight: on ? .bold : .medium))
                                .foregroundStyle(on ? BC.ink : BC.mute)
                        }
                    }
                    .buttonStyle(PressStyle())
                    .accessibilityLabel("\(set.name) pieces")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.horizontal, BC.side)
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, -BC.side)
    }

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var historyRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("How far back").font(.bcRowTitle).foregroundStyle(BC.ink)
                Text("Games, insights and training use this").font(.bcCaption).foregroundStyle(BC.mute)
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
            Spacer(minLength: 6)
            Menu {
                Picker("How far back", selection: Binding(get: { progress.settings.historyMonths },
                                                         set: { Feel.tick(); progress.settings.historyMonths = $0 })) {
                    ForEach(AppSettings.historyOptions, id: \.0) { Text($0.1).tag($0.0) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(AppSettings.historyName(progress.settings.historyMonths))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold))
                }
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(BC.ink)
                .padding(.horizontal, 12).frame(height: 34)
                .background(BC.raised, in: Capsule())
                .fixedSize()
            }
        }
        .padding(.vertical, 10)
    }

    private func toggle(_ title: String, _ key: WritableKeyPath<AppSettings, Bool>) -> some View {
        Toggle(isOn: Binding(get: { progress.settings[keyPath: key] },
                             set: { Feel.tick(); progress.settings[keyPath: key] = $0 })) {
            Text(title).font(.bcRowTitle).foregroundStyle(BC.ink).lineLimit(1).minimumScaleFactor(0.8)
        }
        .tint(BC.mint)
        .frame(minHeight: 52)
    }

    private func stepper(_ title: String, sub: String, _ key: WritableKeyPath<AppSettings, Int>, _ range: ClosedRange<Int>) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.bcRowTitle).foregroundStyle(BC.ink)
                Text(sub).font(.bcCaption).foregroundStyle(BC.mute).lineLimit(1).minimumScaleFactor(0.8)
            }
            Spacer(minLength: 4)
            HStack(spacing: 0) {
                stepButton("minus", enabled: progress.settings[keyPath: key] > range.lowerBound) {
                    progress.settings[keyPath: key] = max(range.lowerBound, progress.settings[keyPath: key] - 1)
                }
                Text("\(progress.settings[keyPath: key])")
                    .font(.system(size: 16, weight: .bold).monospacedDigit()).foregroundStyle(BC.ink)
                    .frame(minWidth: 30)
                    .contentTransition(.numericText())
                stepButton("plus", enabled: progress.settings[keyPath: key] < range.upperBound) {
                    progress.settings[keyPath: key] = min(range.upperBound, progress.settings[keyPath: key] + 1)
                }
            }
            .background(BC.raised, in: Capsule())
        }
        .padding(.vertical, 10)
    }

    private func stepButton(_ icon: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button {
            Feel.tick()
            withAnimation(BC.curve(0.2)) { action() }
        } label: {
            Image(systemName: icon).font(.system(size: 13, weight: .bold))
                .foregroundStyle(enabled ? BC.ink : BC.faint)
                .frame(width: 38, height: 34).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func about(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.bcBodyStrong).foregroundStyle(BC.ink)
            Text(text).font(.bcCaption).foregroundStyle(BC.mute).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Link a chess.com account: just the username. Games are public, so nothing else is needed.
struct LinkView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var progress: ProgressStore
    @EnvironmentObject var store: GameStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var checking = false
    @State private var found: ChessCom.Profile?
    @State private var stats: ChessCom.Stats?
    @State private var error: String?
    @State private var confirmUnlink = false
    @FocusState private var focused: Bool

    private var linked: String { progress.settings.chessComUser }
    private var isCurrent: Bool { !linked.isEmpty && found?.username.lowercased() == linked.lowercased() }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: "chess.com")
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(linked.isEmpty ? "Bring in your games" : "Your account").font(.bcSheetTitle).foregroundStyle(BC.ink)
                        Text("Just your username, no password. Your games are public, so Chess Blanc only reads them.")
                            .font(.bcBody).foregroundStyle(BC.mute).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 8)

                    VStack(alignment: .leading, spacing: 8) {
                        LabelText("Username").padding(.horizontal, 4)
                        HStack(spacing: 10) {
                            Image(systemName: "at").font(.system(size: 15, weight: .semibold)).foregroundStyle(BC.mute)
                            TextField("", text: $name, prompt: Text("your chess.com username").foregroundColor(BC.faint))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .textContentType(.username)
                                .font(.system(size: 17)).foregroundStyle(BC.ink)
                                .submitLabel(.search)
                                .focused($focused)
                                .onSubmit { Task { await lookUp() } }
                                .onChange(of: name) { _, _ in
                                    if found?.username.lowercased() != name.trimmingCharacters(in: .whitespaces).lowercased() { found = nil; stats = nil }
                                    error = nil
                                }
                            if checking { ProgressView().tint(BC.mute).controlSize(.small) }
                            else if found != nil { Image(systemName: "checkmark.circle.fill").foregroundStyle(BC.mint) }
                        }
                        .padding(.horizontal, 16).frame(height: 54)
                        .background(BC.card, in: RoundedRectangle(cornerRadius: BC.rRow, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: BC.rRow, style: .continuous)
                            .stroke(found != nil ? BC.mint.opacity(0.5) : error != nil ? BC.coral.opacity(0.5) : BC.line, lineWidth: 1))
                        .contentShape(Rectangle())
                        .onTapGesture { focused = true }
                        if let error {
                            Text(error).font(.bcCaption).foregroundStyle(BC.coral).padding(.horizontal, 4)
                        }
                    }

                    if let found { preview(found).transition(.move(edge: .bottom).combined(with: .opacity)) }
                }
                .padding(.horizontal, BC.side).padding(.bottom, 160)
                .readableColumn()
                .animation(BC.curve(0.35), value: found?.username)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Spotlight(colour: app.tab.light))
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 4) {
                if isCurrent {
                    BlockButton(title: "Sync games now", systemImage: "arrow.triangle.2.circlepath", enabled: !store.importing) { syncAgain() }
                } else {
                    BlockButton(title: found == nil ? "Look up" : "Link \(found!.username)",
                                systemImage: found == nil ? "magnifyingglass" : "link",
                                enabled: !name.trimmingCharacters(in: .whitespaces).isEmpty && !checking) {
                        if found == nil { Task { await lookUp() } } else { link() }
                    }
                }
                if !linked.isEmpty {
                    QuietButton(title: "Unlink \(linked)", colour: BC.mute) { confirmUnlink = true }
                } else {
                    Text("Read only. Nothing is ever posted to chess.com.").font(.bcCaption).foregroundStyle(BC.mute)
                        .padding(.vertical, 8)
                }
            }
            .padding(.horizontal, BC.side).padding(.top, 10).padding(.bottom, 6)
            .readableColumn()
        }
        .confirmationDialog("Unlink \(linked)?", isPresented: $confirmUnlink, titleVisibility: .visible) {
            Button("Unlink and remove games", role: .destructive) {
                store.cancelReviews()
                store.removeAll()
                progress.settings.chessComUser = ""
                found = nil; stats = nil; name = ""
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your imported games and their reviews are removed from this phone. Opening progress stays.")
        }
        .onAppear {
            guard name.isEmpty, !linked.isEmpty else { return }
            name = linked
            Task { await lookUp() }
        }
    }

    private func preview(_ p: ChessCom.Profile) -> some View {
        CardBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Text(String(p.username.prefix(1)).uppercased())
                        .font(.system(size: 20, weight: .bold)).foregroundStyle(BC.ink)
                        .frame(width: 48, height: 48)
                        .background(BC.raised2, in: RoundedRectangle(cornerRadius: BC.rTile, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.username).font(.bcCardTitle).foregroundStyle(BC.ink).lineLimit(1).minimumScaleFactor(0.7)
                        if let j = p.joined {
                            Text("On chess.com since \(Date(timeIntervalSince1970: j).formatted(.dateTime.month(.wide).year()))")
                                .font(.bcCaption).foregroundStyle(BC.mute).lineLimit(1).minimumScaleFactor(0.85)
                        }
                    }
                    Spacer(minLength: 0)
                    if isCurrent { Tag(text: "Linked", colour: BC.mint) }
                }
                HStack(spacing: 8) {
                    rating("Rapid", stats?.chess_rapid?.last?.rating)
                    rating("Blitz", stats?.chess_blitz?.last?.rating)
                    rating("Bullet", stats?.chess_bullet?.last?.rating)
                }
                if isCurrent {
                    Text(store.importing ? (store.status ?? "Syncing…") : "\(store.games.count) games in the last \(AppSettings.historyName(progress.settings.historyMonths)) · \(store.reviewed.count) reviewed")
                        .font(.bcCaption).foregroundStyle(BC.mute).lineLimit(1).minimumScaleFactor(0.8)
                }
            }
        }
    }

    private func rating(_ label: String, _ v: Int?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LabelText(label)
            Text(v.map(String.init) ?? "–").font(.system(size: 20, weight: .bold).monospacedDigit()).foregroundStyle(BC.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(BC.raised, in: RoundedRectangle(cornerRadius: BC.rTile, style: .continuous))
    }

    private func lookUp() async {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !checking else { return }
        focused = false
        checking = true
        error = nil
        defer { checking = false }
        do {
            let p = try await ChessCom.profile(n)
            stats = try? await ChessCom.stats(n)
            found = p
            Feel.tap()
        } catch {
            found = nil
            self.error = (error as? ChessCom.Failure)?.errorDescription ?? "Couldn't reach chess.com. Check your connection."
            Feel.error()
        }
    }

    private func link() {
        guard let found else { return }
        if !linked.isEmpty && linked.lowercased() != found.username.lowercased() {
            store.cancelReviews()
            store.removeAll()
        }
        progress.settings.chessComUser = found.username
        Feel.gained()
        syncAgain()
        dismiss()
    }

    private func syncAgain() {
        let s = progress.settings
        Task { await store.sync(user: s.chessComUser, months: s.historyMonths, autoReview: s.autoReview) }
    }
}


/// A 4×4 corner of a board in a theme, with a knight on it.
private struct ThemeSwatch: View {
    let theme: BoardTheme
    var body: some View {
        GeometryReader { geo in
            let q = geo.size.width / 4
            ZStack(alignment: .topLeading) {
                ForEach(0..<16, id: \.self) { i in
                    Rectangle().fill((i / 4 + i % 4) % 2 == 0 ? theme.light : theme.dark)
                        .frame(width: q, height: q)
                        .offset(x: CGFloat(i % 4) * q, y: CGFloat(i / 4) * q)
                }
                Rectangle().fill(theme.highlight).frame(width: q, height: q).offset(x: q, y: 2 * q)
                Image(PieceSet.image("wN")).resizable().frame(width: q * 1.6, height: q * 1.6).offset(x: q * 1.2, y: q * 1.2)
            }
        }
    }
}


/// A small lock on a Pro-only look.
private struct LockBadge: View {
    var body: some View {
        Image(systemName: "lock.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.black)
            .frame(width: 18, height: 18).background(Color.white, in: Circle())
            .padding(4)
    }
}


/// Link a Lichess account: just the username; games are read from Lichess's open API.
struct LichessLinkView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var progress: ProgressStore
    @EnvironmentObject var store: GameStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var checking = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: "Lichess")
            VStack(alignment: .leading, spacing: 16) {
                Text(progress.settings.lichessUser.isEmpty ? "Bring in your Lichess games" : "Linked: \(progress.settings.lichessUser)")
                    .font(.bcSheetTitle).foregroundStyle(BC.ink)
                Text("Just your username, no password. Lichess games are public, so Chess Blanc only reads them.")
                    .font(.bcBody).foregroundStyle(BC.mute).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Image(systemName: "at").font(.system(size: 15, weight: .semibold)).foregroundStyle(BC.mute)
                    TextField("", text: $name, prompt: Text("your Lichess username").foregroundColor(BC.faint))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.system(size: 17)).foregroundStyle(BC.ink)
                        .focused($focused).submitLabel(.done)
                        .onSubmit { Task { await link() } }
                    if checking { ProgressView().tint(BC.mute).controlSize(.small) }
                }
                .padding(.horizontal, 16).frame(height: 54)
                .background(BC.card, in: RoundedRectangle(cornerRadius: BC.rRow, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: BC.rRow, style: .continuous).stroke(error != nil ? BC.coral.opacity(0.5) : BC.line, lineWidth: 1))
                if let error { Text(error).font(.bcCaption).foregroundStyle(BC.coral) }
                BlockButton(title: "Link", systemImage: "link", enabled: !name.trimmingCharacters(in: .whitespaces).isEmpty && !checking) {
                    Task { await link() }
                }
                if !progress.settings.lichessUser.isEmpty {
                    QuietButton(title: "Unlink \(progress.settings.lichessUser)", colour: BC.mute) {
                        progress.settings.lichessUser = ""
                        dismiss()
                    }
                    .frame(maxWidth: .infinity)
                }
                Spacer()
            }
            .padding(.horizontal, BC.side).padding(.top, 12)
            .readableColumn()
        }
        .background(Spotlight(colour: BC.blue))
        .onAppear { name = progress.settings.lichessUser; focused = name.isEmpty }
    }

    private func link() async {
        checking = true
        error = nil
        defer { checking = false }
        do {
            guard let found = try await Lichess.user(name) else { error = "No Lichess player with that username."; return }
            progress.settings.lichessUser = found
            store.lichessUser = found
            Feel.success()
            let s = progress.settings
            Task { await store.sync(user: s.chessComUser, months: s.historyMonths, autoReview: s.autoReview) }
            dismiss()
        } catch {
            self.error = "Couldn't reach Lichess. Try again."
        }
    }
}
