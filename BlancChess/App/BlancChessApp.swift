import SwiftUI
import UIKit

@main
struct BlancChessApp: App {
    @StateObject private var app = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(app.progress)
                .environmentObject(app.games)
                .preferredColorScheme(.dark)
                .tint(BC.ink)
                .task { await Pro.shared.start() }
                .task {
                    await app.load()
                    // Sounds and haptics get ready once the first screen is up (they load on first use before that).
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    Feel.prepare()
                    // Let the first screen settle before Stockfish loads its networks.
                    try? await Task.sleep(nanoseconds: 950_000_000)
                    await EngineService.shared.prepare()
                    let s = app.progress.settings
                    if s.linked {
                        await app.games.sync(user: s.chessComUser, months: s.historyMonths, autoReview: s.autoReview)
                        if s.autoReview { app.games.enqueueReviews(app.games.unreviewed.prefix(10).map(\.id)) }
                    }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var progress: ProgressStore
    @ObservedObject private var pro = Pro.shared
    @Environment(\.scenePhase) private var phase
    @State private var onboarding = false
    /// Tabs opened so far. They stay alive (their screens, scroll and state) when you switch away.
    @State private var visited: Set<Tab> = []

    var body: some View {
        ZStack(alignment: .bottom) {
            if app.loaded {
                ZStack {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        if tab == app.tab || visited.contains(tab) {
                            let on = tab == app.tab
                            stack(tab)
                                .environment(\.tabVisible, on)
                                .animation(.easeOut(duration: 0.12)) { $0.opacity(on ? 1 : 0) }
                                .allowsHitTesting(on)
                                .accessibilityHidden(!on)
                                .zIndex(on ? 1 : 0)
                                .transition(.opacity.animation(.easeOut(duration: 0.12)))
                        }
                    }
                }
                .onChange(of: app.tab, initial: true) { _, t in visited.insert(t) }
                if (app.paths[app.tab] ?? []).isEmpty { Dock().transition(.move(edge: .bottom).combined(with: .opacity)) }
            } else {
                LaunchCover()
            }
        }
        .background(BC.bg.ignoresSafeArea())
        .sheet(item: $pro.paywall) { reason in
            PaywallView(reason: reason).presentationDetents([.large])
        }
        // First launch only, once saved settings are in (so anyone already set up never sees it).
        .onChange(of: app.loaded, initial: true) { _, loaded in
            if loaded && OnboardingView.needed(progress.settings) { onboarding = true }
        }
        .fullScreenCover(isPresented: $onboarding) {
            OnboardingView { onboarding = false }
                .environmentObject(app).environmentObject(progress).environmentObject(app.games)
        }
        .animation(BC.curve(0.3), value: (app.paths[app.tab] ?? []).isEmpty)
        // Back from playing on chess.com: fetch the new games (at most once a minute).
        .onChange(of: phase) { _, p in
            // Background reviews pause while the app isn't in front; unsaved work is written now.
            ReviewGate.shared.appActive = p == .active
            if p != .active {
                progress.flush()
                app.games.flush()
            }
            let s = progress.settings
            guard p == .active, app.loaded, s.linked,
                  Date().timeIntervalSince(app.games.lastSync ?? .distantPast) > 60 else { return }
            Task { await app.games.sync(user: s.chessComUser, months: s.historyMonths, autoReview: s.autoReview) }
        }
        .onChange(of: progress.settings.lichessUser, initial: true) { _, u in app.games.lichessUser = u }
        .onChange(of: progress.settings.historyMonths) { old, new in
            app.games.windowMonths = new
            let s = progress.settings
            if (new == 0 || (old != 0 && new > old)), s.linked {
                Task { await app.games.sync(user: s.chessComUser, months: new, autoReview: s.autoReview) }
            }
        }
    }

    private func stack(_ tab: Tab) -> some View {
        NavigationStack(path: app.path(tab)) {
            root(tab)
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: Route.self) { route in
                    destination(route).toolbar(.hidden, for: .navigationBar)
                }
        }
    }

    @ViewBuilder
    private func root(_ tab: Tab) -> some View {
        switch tab {
        case .today: TodayView()
        case .openings: OpeningsView()
        case .games: GamesView()
        case .board: AnalysisBoardView(start: nil)
        case .insights: InsightsView()
        }
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case let .explore(rep, node): ExploreView(repID: rep, nodeID: node)
        case .opening(let id): OpeningPage(repID: id)
        case .practice(let req): PracticeView(request: req)
        case let .spar(rep, node): SparView(repID: rep, nodeID: node)
        case .game(let id): GameReviewView(gameID: id)
        case .board(let start): AnalysisBoardView(start: start)
        case .puzzles(let set): PuzzleRunView(set: set)
        case .weakness(let kind): WeaknessView(kind: kind)
        case .endgames: EndgamesView()
        case .blunderCheck: BlunderCheckView()
        case .weeklyReport: WeeklyReportView()
        case .endgame(let id): EndgameDrillView(drillID: id)
        case .settings: SettingsView()
        case .link: LinkView()
        case .linkLichess: LichessLinkView()
        }
    }
}

extension EnvironmentValues {
    /// False for a tab kept alive behind the one you're on: it should stop ongoing work (engine analysis).
    @Entry var tabVisible = true
}

/// The floating dock: a 64 tall glass capsule of five symbols, no words (BNShellTabBar).
struct Dock: View {
    @EnvironmentObject var app: AppModel
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { t in
                let on = app.tab == t
                Button {
                    if app.tab == t { app.popToRoot(t) } else { Feel.tick(); app.tab = t }
                } label: {
                    Image(systemName: on ? t.iconOn : t.icon)
                        .font(.system(size: 24, weight: on ? .semibold : .regular))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(on ? BC.ink : BC.mute)
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel(t.title)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .frame(height: 64)
        .background { glass }
        .frame(maxWidth: BC.dockWidth)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    @ViewBuilder private var glass: some View {
        if #available(iOS 26.0, *) {
            Capsule().fill(Color.clear)
                .glassEffect(.regular.tint(Color.black.opacity(0.35)), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        } else {
            Capsule().fill(Color(hex: 0x1C1C20, opacity: 0.72))
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        }
    }
}

/// The only full-screen cover: the mark on its light, while the repertoires load.
struct LaunchCover: View {
    @State private var shown = false
    var body: some View {
        ZStack {
            Spotlight(colour: BC.blue, strength: 0.3, anchor: UnitPoint(x: 0.5, y: 0.45))
            Image("LaunchMark").resizable().scaledToFit().frame(width: 96)
                .opacity(shown ? 1 : 0).scaleEffect(shown ? 1 : 0.96)
        }
        .onAppear { withAnimation(BC.curve(0.5)) { shown = true } }
    }
}

/// The system navigation bar is hidden for the custom headers, which also turns off swipe-to-go-back.
/// This turns it back on for every pushed screen.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
