import SwiftUI

enum Tab: String, Hashable, CaseIterable {
    case today, openings, games, board, insights
    var title: String {
        switch self { case .today: "Today"; case .openings: "Openings"; case .games: "Games"; case .board: "Board"; case .insights: "Insights" }
    }
    var icon: String {
        switch self {
        case .today: "house"; case .openings: "book.closed"; case .games: "list.bullet.rectangle.portrait"
        case .board: "square.grid.3x3"; case .insights: "chart.line.uptrend.xyaxis"
        }
    }
    var iconOn: String {
        switch self {
        case .today: "house.fill"; case .openings: "book.closed.fill"; case .games: "list.bullet.rectangle.portrait.fill"
        case .board: "square.grid.3x3.fill"; case .insights: "chart.line.uptrend.xyaxis"
        }
    }
    /// Each place has its light.
    var light: Color {
        switch self { case .today: BC.amber; case .openings: BC.blue; case .games: BC.mint; case .board: BC.violet; case .insights: BC.coral }
    }
}

/// What an opening practice session should cover.
struct PracticeRequest: Hashable {
    enum Mode: String, Hashable {
        case review      // moves that are due
        case learn       // new moves, most common first
        case mixed       // due first, then a few new ones (the daily session)
        case all         // every move in the chosen part, due or not
        case revise      // moves you've learned, in a random order, from random setups
        case session     // a 15-minute block: due, then new, then revision, about 20 lines
    }
    var repID: String? = nil      // nil = every opening in your repertoire
    var repIDs: [String]? = nil   // several chosen openings (one side's study card)
    var mode: Mode = .mixed
    var nodeID: String? = nil     // limit to this branch (a chapter, a line, a position)
    var title: String = "Practice"
}

/// Where the analysis board starts.
struct BoardStart: Hashable {
    var fen: String = Chess.startFEN
    var history: [String] = []
    var title: String = "Analysis"
    var flipped: Bool = false
}

/// A run of positions to solve.
struct PuzzleSet: Hashable {
    enum Source: Hashable {
        case daily                     // today's mix
        case mistakes(String?)         // your slips; optional filter: phase name or move class
        case weakness(String)          // Weakness.Kind raw value
        case game(String)              // the slips from one game
    }
    var source: Source
    var title: String
}

enum Route: Hashable {
    // Openings
    case explore(rep: String, node: String)
    case opening(String)
    case practice(PracticeRequest)
    case spar(rep: String, node: String)
    // Games
    case game(String)
    // Board
    case board(BoardStart)
    // Training
    case puzzles(PuzzleSet)
    case weakness(String)
    case endgames
    case blunderCheck
    case weeklyReport
    case endgame(String)
    // Account
    case settings
    case link
    case linkLichess
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    /// The openings you're learning (your repertoire): practice, Today and coverage use these.
    @Published var repertoires: [Repertoire] = []
    /// Every opening in the library, and the packs opened so far.
    @Published private(set) var library: [LibraryEntry] = []
    @Published private(set) var packs: [String: Repertoire] = [:]
    @Published private(set) var activeIDs: [String] = UserDefaults.standard.stringArray(forKey: "bc.activeReps") ?? ["white", "black"]
    @Published private(set) var book: OpeningBook?
    @Published var tab: Tab = .today
    @Published var paths: [Tab: [Route]] = [:]
    @Published private(set) var loaded = false

    let progress = ProgressStore()
    let games = GameStore()

    init() {
        Feel.prepare()
        games.windowMonths = progress.settings.historyMonths
        // Where your games leave your prep becomes a due move (GameStore doesn't know ProgressStore).
        let progress = self.progress
        games.onLeftPrep = { rep, node in progress.markDue(rep, node) }
    }

    /// Loads the repertoires and opening book off the main thread.
    func load() async {
        guard !loaded else { return }
        async let reps = RepertoireLoader.loadAll()
        async let book = OpeningBook.load()
        async let index = RepertoireLoader.loadIndex()
        let (r, b, ix) = await (reps, book, index)
        library = ix
        for rep in r { packs[rep.id] = rep }
        for id in activeIDs where packs[id] == nil {
            if let p = await RepertoireLoader.load(id) { packs[id] = p }
        }
        repertoires = activeIDs.compactMap { packs[$0] }
        self.book = b
        games.reps = r
        games.book = b
        loaded = true
    }

    func repertoire(_ id: String) -> Repertoire? { packs[id] ?? repertoires.first { $0.id == id } }

    /// Every opening loaded so far, yours first.
    var allLoaded: [Repertoire] { repertoires + packs.values.filter { p in !repertoires.contains { $0.id == p.id } } }

    func isActive(_ id: String) -> Bool { activeIDs.contains(id) }

    /// Loads a library opening (cached).
    func pack(_ id: String) async -> Repertoire? {
        if let p = packs[id] { return p }
        let p = await RepertoireLoader.load(id)
        if let p { packs[id] = p }
        return p
    }

    /// Adds an opening to your repertoire, or takes it out.
    func setActive(_ id: String, _ on: Bool) {
        if on, !activeIDs.contains(id) { activeIDs.append(id) }
        if !on { activeIDs.removeAll { $0 == id } }
        UserDefaults.standard.set(activeIDs, forKey: "bc.activeReps")
        repertoires = activeIDs.compactMap { packs[$0] }
        games.reps = repertoires
    }
    func repertoire(for color: PieceColor) -> Repertoire? { repertoires.first { $0.color == color } }

    func path(_ tab: Tab) -> Binding<[Route]> {
        Binding(get: { self.paths[tab] ?? [] }, set: { self.paths[tab] = $0 })
    }

    /// Push a screen onto the current tab.
    func open(_ route: Route) {
        paths[tab, default: []].append(route)
    }

    /// Switch tab and show exactly this screen there (replaces that tab's stack, so Back goes to the tab's root).
    func go(_ tab: Tab, _ route: Route? = nil) {
        self.tab = tab
        paths[tab] = route.map { [$0] } ?? []
    }

    func popToRoot(_ tab: Tab) { paths[tab] = [] }
}
