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
    /// The product is being fetched from the App Store.
    @Published private(set) var loading = false
    /// Something to tell the buyer (a failed load, a failed or pending purchase, nothing to restore).
    @Published var notice: String?
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
        // Builds installed from a Mac carry a provisioning profile; App Store and TestFlight builds don't.
        // Belt and braces: if Apple says this copy came from the App Store, TestFlight or App Review (any
        // sandbox or production App Transaction), it is never a developer build, so the paywall always shows.
        var fromMac = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") != nil
        if fromMac, let result = try? await AppTransaction.shared, case .verified(let t) = result,
           t.environment == .sandbox || t.environment == .production {
            fromMac = false
        }
        developer = fromMac
        #endif
        Daily.pruneOldDays()
        await refresh()
        await loadProduct()
    }

    /// Fetches the subscription from the App Store, retrying a few times: the paywall must always end up
    /// with something to buy, or say clearly that the App Store couldn't be reached (with a retry).
    func loadProduct() async {
        guard product == nil, !loading else { return }
        loading = true
        defer { loading = false }
        for attempt in 0..<4 {
            do {
                if let p = try await Product.products(for: [Self.monthlyID]).first {
                    product = p
                    // Only call it a free trial when the App Store really has one for this buyer.
                    let eligible = await p.subscription?.isEligibleForIntroOffer ?? false
                    trialAvailable = eligible && p.subscription?.introductoryOffer?.paymentMode == .freeTrial
                    notice = nil
                    return
                }
                // The App Store answered but didn't offer the product (not yet live in this region, or a
                // temporary App Store problem): retry, then say so plainly.
                notice = "Chess Blanc Pro isn't available from the App Store right now. Try again in a moment."
            } catch {
                notice = "Couldn't reach the App Store. Check your connection and try again."
            }
            try? await Task.sleep(for: .seconds(Double(attempt + 1)))
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
        guard !busy else { return }
        if product == nil { await loadProduct() }
        guard let product else { return }
        busy = true
        notice = nil
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(let result):
                guard case .verified(let t) = result else {
                    notice = "The App Store couldn't verify that purchase. Try Restore, or try again."
                    return
                }
                await t.finish()
                await refresh()
                if !subscribed { subscribed = t.productID == Self.monthlyID && t.revocationDate == nil }
                if subscribed { Feel.complete(); paywall = nil }
            case .pending:
                notice = "Your purchase is waiting for approval. Pro turns on as soon as it's approved."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            notice = "The purchase didn't go through: \(error.localizedDescription)"
        }
    }

    func restore() async {
        busy = true
        notice = nil
        defer { busy = false }
        do { try await AppStore.sync() } catch {
            notice = "Couldn't reach the App Store to restore. Try again in a moment."
            return
        }
        await refresh()
        if subscribed { Feel.complete(); paywall = nil } else { notice = "No active Chess Blanc Pro subscription was found for this Apple ID." }
    }

    /// "7 days", "1 week", "1 month": the free trial's length, from the App Store's own offer.
    var trialLength: String? {
        guard let offer = product?.subscription?.introductoryOffer, offer.paymentMode == .freeTrial else { return nil }
        let n = offer.period.value
        let unit: String
        switch offer.period.unit {
        case .day: unit = n == 1 ? "day" : "days"
        case .week: unit = n == 1 ? "week" : "weeks"
        case .month: unit = n == 1 ? "month" : "months"
        case .year: unit = n == 1 ? "year" : "years"
        @unknown default: unit = "days"
        }
        return "\(n) \(unit)"
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
    /// Drops counts from earlier days (called once at launch).
    static func pruneOldDays() {
        let keep = "daily.\(today)."
        for k in UserDefaults.standard.dictionaryRepresentation().keys where k.hasPrefix("daily.") && !k.hasPrefix(keep) {
            UserDefaults.standard.removeObject(forKey: k)
        }
    }

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
                    legal
                }
                .padding(.horizontal, BC.side)
                .padding(.top, 8)
                .padding(.bottom, 16)
                .readableColumn()
            }
            .scrollIndicators(.hidden)
            // The price, the button and the links stay on screen at every size (iPad sheets, iPhone SE).
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 10) {
                    priceBox
                    links
                }
                .padding(.horizontal, BC.side).padding(.top, 14).padding(.bottom, 10)
                .readableColumn()
                .frame(maxWidth: .infinity)
                .background(BC.sheet.ignoresSafeArea(edges: .bottom))
                .overlay(alignment: .top) {
                    LinearGradient(colors: [BC.sheet.opacity(0), BC.sheet], startPoint: .top, endPoint: .bottom)
                        .frame(height: 28).offset(y: -28).allowsHitTesting(false)
                }
            }
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
        .onAppear { pro.notice = nil; withAnimation(BC.curve(0.6)) { shown = true } }
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
                    .lineLimit(1).minimumScaleFactor(0.68)
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
                // The amount billed is the most prominent price on the screen (App Review 3.1.2).
                Text("\(price) / month")
                    .font(.system(size: 26, weight: .bold)).foregroundStyle(BC.ink)
                if pro.trialAvailable, let trial = pro.trialLength {
                    Text("Free for \(trial), then \(price) every month until you cancel.")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(BC.mute)
                        .multilineTextAlignment(.center)
                }
                BlockButton(title: pro.trialAvailable ? "Try it free" : "Subscribe for \(price) / month",
                            systemImage: "sparkles", enabled: !pro.busy) {
                    Task { await pro.purchase() }
                }
            } else if pro.loading {
                ProgressView().tint(BC.ink).frame(height: 56)
                Text("Loading from the App Store…").font(.system(size: 13, weight: .medium)).foregroundStyle(BC.mute)
            } else {
                BlockButton(title: "Try again", systemImage: "arrow.clockwise", enabled: true) {
                    Task { await pro.loadProduct() }
                }
            }
            if let notice = pro.notice {
                Text(notice)
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(BC.amber)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            if pro.busy { ProgressView().tint(BC.mute) }
        }
        .task { await pro.loadProduct() }
    }

    /// Auto-renewal terms (App Review 3.1.2, UK consumer law), worded for whether a free trial applies.
    private var legalText: String {
        if pro.trialAvailable, let trial = pro.trialLength {
            return "Chess Blanc Pro is an auto-renewing monthly subscription. It's free for \(trial); unless you cancel at least 24 hours before the trial ends, your Apple ID is charged \(price) then and every month after until you cancel. Manage or cancel any time in Settings › your name › Subscriptions."
        }
        return "Chess Blanc Pro is an auto-renewing monthly subscription. \(price) is charged to your Apple ID when you confirm, and again every month unless you cancel at least 24 hours before the end of the current period. Manage or cancel any time in Settings › your name › Subscriptions."
    }

    private var links: some View {
        HStack(spacing: 18) {
            Button("Restore") { Task { await pro.restore() } }.disabled(pro.busy)
            Link("Terms of Use", destination: Legal.terms)
            Link("Privacy Policy", destination: Legal.privacy)
        }
        .font(.system(size: 13, weight: .semibold)).foregroundStyle(BC.mute)
    }

    private var legal: some View {
        Text(legalText)
            .font(.system(size: 11)).foregroundStyle(BC.faint).multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
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
