import SwiftUI
import StoreKit

/// What the free version gives each day. Everything else is free without limits.
enum Allowance: String, Identifiable, CaseIterable {
    case newLines, blunderRounds, positions, looks, general
    var id: String { rawValue }

    /// Free uses per day (looks: how many boards and piece sets are free).
    var limit: Int {
        switch self {
        case .newLines: 10
        case .blunderRounds: 2
        case .positions: 10
        case .looks: 3
        case .general: 0
        }
    }

    var headline: String {
        switch self {
        case .newLines: "You've learned 10 new lines today"
        case .blunderRounds: "That's today's 2 Blunder checks"
        case .positions: "That's today's 10 positions"
        case .looks: "More boards and pieces"
        case .general: ""
        }
    }
}

/// Chess Blanc Pro: one monthly subscription that lifts the daily limits.
@MainActor
final class Pro: ObservableObject {
    static let shared = Pro()
    static let monthlyID = "com.blancnotes.chess.pro.monthly"

    @Published private(set) var subscribed = false
    @Published private(set) var product: Product?
    @Published private(set) var trialAvailable = false
    @Published private(set) var busy = false
    /// A build you installed yourself (Xcode / devicectl), not from the App Store: Pro is on.
    @Published private(set) var developer = false
    /// On a developer build: try the app as a free user.
    @Published var previewFree = UserDefaults.standard.bool(forKey: "pro.previewFree") {
        didSet { UserDefaults.standard.set(previewFree, forKey: "pro.previewFree") }
    }
    /// The paywall to show, and why.
    @Published var paywall: Allowance?
    @Published private(set) var dayKey = Daily.today

    var isPro: Bool { subscribed || (developer && !previewFree) }

    private var updates: Task<Void, Never>?

    func start() async {
        updates = Task.detached {
            for await result in Transaction.updates {
                if case .verified(let t) = result { await t.finish() }
                await Pro.shared.refresh()
            }
        }
        #if targetEnvironment(simulator)
        developer = true
        #else
        // App Store and TestFlight builds carry no provisioning profile; builds installed from a Mac do.
        developer = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") != nil
        #endif
        await refresh()
        if let p = try? await Product.products(for: [Self.monthlyID]).first {
            product = p
            trialAvailable = await p.subscription?.isEligibleForIntroOffer ?? false
        }
    }

    func refresh() async {
        var active = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, t.productID == Self.monthlyID, t.revocationDate == nil { active = true }
        }
        subscribed = active
    }

    func purchase() async {
        guard let product, !busy else { return }
        busy = true
        defer { busy = false }
        if case .success(let result) = try? await product.purchase(), case .verified(let t) = result {
            await t.finish()
            await refresh()
            if subscribed { Feel.complete(); paywall = nil }
        }
    }

    func restore() async {
        busy = true
        defer { busy = false }
        try? await AppStore.sync()
        await refresh()
        if subscribed { paywall = nil }
    }

    // MARK: Daily allowance

    /// How many are left today (Int.max with Pro).
    func left(_ a: Allowance) -> Int { isPro ? .max : max(0, a.limit - Daily.used(a)) }

    /// Counts one use. False (and shows the paywall) when the day's allowance is gone.
    @discardableResult
    func use(_ a: Allowance) -> Bool {
        guard !isPro else { return true }
        guard Daily.used(a) < a.limit else { paywall = a; return false }
        Daily.add(a)
        dayKey = Daily.today
        objectWillChange.send()
        return true
    }

    /// Is this board or piece set (by its place in the list) free?
    func lookFree(_ index: Int) -> Bool { isPro || index < Allowance.looks.limit }
}

/// Today's counts, kept per calendar day.
enum Daily {
    static var today: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
    static func used(_ a: Allowance) -> Int { UserDefaults.standard.integer(forKey: "daily.\(today).\(a.rawValue)") }
    static func add(_ a: Allowance) {
        UserDefaults.standard.set(used(a) + 1, forKey: "daily.\(today).\(a.rawValue)")
    }
}

/// The one paywall: your icon, what stays free against what Pro adds, the price, one button.
struct PaywallView: View {
    let reason: Allowance?
    @ObservedObject var pro = Pro.shared
    @Environment(\.dismiss) private var dismiss
    @State private var shown = false

    private var price: String { pro.product?.displayPrice ?? "£2.99" }

    var body: some View {
        ZStack(alignment: .top) {
            BC.sheet.ignoresSafeArea()
            RadialGradient(colors: [BC.blue.opacity(0.45), .clear], center: .top, startRadius: 0, endRadius: 420)
                .frame(height: 520).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 22) {
                    hero
                    if let reason, reason != .general {
                        Text(reason.headline)
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(BC.amber)
                            .padding(.horizontal, 12).frame(height: 30)
                            .background(BC.amber.opacity(0.14), in: Capsule())
                    }
                    comparison
                    priceBox
                    footer
                }
                .padding(.horizontal, BC.side)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .readableColumn()
            }
            .scrollIndicators(.hidden)
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(BC.mute)
                        .frame(width: 32, height: 32).background(Color.white.opacity(0.08), in: Circle())
                }
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, BC.side).padding(.top, 14)
        }
        .onAppear { withAnimation(BC.curve(0.6)) { shown = true } }
        .onChange(of: pro.isPro) { _, on in if on { dismiss() } }
    }

    private var hero: some View {
        VStack(spacing: 14) {
            Image("BrandIcon").resizable().scaledToFit()
                .frame(width: 104, height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: BC.blue.opacity(0.55), radius: 28, y: 6)
                .scaleEffect(shown ? 1 : 0.9).opacity(shown ? 1 : 0)
                .padding(.top, 34)
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Text("Chess Blanc").font(.system(size: 30, weight: .bold)).tracking(-0.6)
                    Text("PRO").font(.system(size: 13, weight: .heavy)).tracking(1)
                        .foregroundStyle(.black).padding(.horizontal, 8).frame(height: 22)
                        .background(BC.blue, in: Capsule())
                }
                .foregroundStyle(BC.ink)
                Text("Everything stays free. Pro takes the daily limits off.")
                    .font(.bcBody).foregroundStyle(BC.mute).multilineTextAlignment(.center)
            }
        }
    }

    /// Free against Pro, row by row.
    private var comparison: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Text("Free").frame(width: 70)
                Text("Pro").foregroundStyle(BC.blue).frame(width: 64)
            }
            .font(.system(size: 12, weight: .bold)).tracking(0.6).foregroundStyle(BC.mute)
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
            line("sparkles", "New opening lines", "10 a day")
            line("shield.lefthalf.filled", "Blunder check", "2 a day")
            line("scope", "Game positions", "10 a day")
            line("paintpalette", "Boards and pieces", "3 each")
            line("cpu", "Reviews and analysis", nil)
            line("book.closed", "Every opening", nil, last: true)
        }
        .background(BC.card, in: RoundedRectangle(cornerRadius: BC.rCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BC.rCard, style: .continuous).stroke(BC.line, lineWidth: 1))
    }

    /// One row: the feature, what free gets (nil = all of it), and Pro's unlimited.
    private func line(_ icon: String, _ title: String, _ free: String?, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(BC.blue).frame(width: 22)
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(BC.ink)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                Group {
                    if let free { Text(free).font(.system(size: 13)).foregroundStyle(BC.mute) }
                    else { Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(BC.mute) }
                }
                .frame(width: 70)
                Group {
                    if free != nil { Image(systemName: "infinity").font(.system(size: 15, weight: .bold)) }
                    else { Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)) }
                }
                .foregroundStyle(BC.mint).frame(width: 64)
            }
            .padding(.horizontal, 16).frame(minHeight: 48)
            if !last { Rectangle().fill(BC.line).frame(height: 1).padding(.leading, 48) }
        }
    }

    @ViewBuilder
    private var priceBox: some View {
        VStack(spacing: 10) {
            if pro.product != nil {
                BlockButton(title: pro.trialAvailable ? "Start your free week" : "Get Pro", systemImage: "sparkles",
                            enabled: !pro.busy) {
                    Task { await pro.purchase() }
                }
                Text(pro.trialAvailable ? "7 days free, then \(price) a month. Cancel any time."
                                        : "\(price) a month. Cancel any time.")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(BC.mute)
            } else {
                BlockButton(title: "Coming soon", systemImage: "sparkles", enabled: false) {}
                Text("Pro will be \(price) a month, with a free week to try it.")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(BC.mute)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 18) {
                Button("Restore") { Task { await pro.restore() } }
                Link("Terms of Use", destination: Legal.terms)
                Link("Privacy Policy", destination: Legal.privacy)
            }
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(BC.mute)
            Text("Payment is charged to your Apple ID. The subscription renews monthly unless cancelled at least 24 hours before the period ends; manage it in Settings › Apple ID › Subscriptions.")
                .font(.system(size: 11)).foregroundStyle(BC.faint).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Where the policies live (the Chess Blanc site on GitHub Pages, and Apple's standard licence).
enum Legal {
    static let site = URL(string: "https://drz77zgr4j-cloud.github.io/chess-blanc/")!
    static let privacy = URL(string: "https://drz77zgr4j-cloud.github.io/chess-blanc/privacy/")!
    static let support = URL(string: "https://drz77zgr4j-cloud.github.io/chess-blanc/support/")!
    static let terms = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let source = URL(string: "https://github.com/drz77zgr4j-cloud/chess-blanc")!
}

/// Privacy, terms, support and source, in one quiet row.
struct LegalLinks: View {
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { links }
            VStack(alignment: .leading, spacing: 8) { links }
        }
        .font(.system(size: 13, weight: .semibold)).foregroundStyle(BC.blue)
    }

    @ViewBuilder private var links: some View {
        Link("Privacy Policy", destination: Legal.privacy)
        Link("Terms of Use", destination: Legal.terms)
        Link("Support", destination: Legal.support)
        Link("Source code", destination: Legal.source)
    }
}
