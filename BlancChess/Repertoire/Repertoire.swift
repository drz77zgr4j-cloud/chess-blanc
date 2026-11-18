import Foundation

// MARK: - JSON

private struct RepNodeDTO: Decodable {
    let uci: String
    let san: String
    let ply: Int
    let fen: String?
    let games: Int?
    let share: Double?
    let eval: Double?
    let results: [Double]?
    let opening: String?
    let note: String?
    let why: String?
    let reach: Double?
    let trap: Bool?
    let brilliant: Bool?
    let transposes: String?
    let continuation: [String]?
    let children: [RepNodeDTO]
}

private struct RepertoireDTO: Decodable {
    let id: String
    let name: String
    let color: String
    let summary: String
    let source: String
    let built: String
    let tree: RepNodeDTO
    let setup: [String]?
    let title: String?
    let family: String?
    let blurb: String?
    let popularity: Double?
}

// MARK: - Model

/// One position in a repertoire, reached by `uci` from its parent. The root is the starting position.
final class RepNode: Identifiable, Hashable {
    let id: String                // UCI path, e.g. "e2e4,e7e5,g1f3" ("" for the root)
    let uci: String
    let san: String
    let ply: Int                  // moves from the start; 1 = first move
    let fenAfter: String
    let games: Int
    let share: Double             // how often this move is chosen here (0…1)
    let eval: Double              // centipawns from White's side after the move
    let results: [Double]?        // white, draw, black
    let opening: String?
    let note: String?
    let why: String?              // "theory", "yours", "popular", "engine"
    let reach: Double             // share of your games that reach this position
    let isTrap: Bool
    let isBrilliant: Bool
    let transposes: String?       // id of the node this position also arises from
    let continuation: [String]    // Stockfish's line after a leaf
    weak var parent: RepNode?
    fileprivate(set) var children: [RepNode] = []

    fileprivate init(dto: RepNodeDTO, path: String, fenBefore: String) {
        id = path
        uci = dto.uci
        ply = dto.ply
        if let f = dto.fen {
            fenAfter = f
        } else if !dto.uci.isEmpty, let p = Chess.play(dto.uci, on: fenBefore) {
            fenAfter = p.fenAfter
        } else {
            fenAfter = fenBefore
        }
        san = dto.san.isEmpty || dto.san == dto.uci ? (Chess.play(dto.uci, on: fenBefore)?.san ?? dto.san) : dto.san
        games = dto.games ?? 0
        share = dto.share ?? 0
        eval = dto.eval ?? 0
        results = dto.results
        opening = dto.opening
        note = dto.note
        why = dto.why
        reach = dto.reach ?? 0
        isTrap = dto.trap ?? false
        isBrilliant = dto.brilliant ?? false
        transposes = dto.transposes
        continuation = dto.continuation ?? []
    }

    static func == (a: RepNode, b: RepNode) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    var isRoot: Bool { uci.isEmpty }
    var fenBefore: String { parent?.fenAfter ?? Chess.startFEN }
    /// Who played this move.
    var mover: PieceColor { ply % 2 == 1 ? .white : .black }
    var numbered: String { isRoot ? "Start" : Chess.numbered(san, fenBefore: fenBefore) }
    var from: String { String(uci.prefix(2)) }
    var to: String { String(uci.dropFirst(2).prefix(2)) }
    var move: MovePair { MovePair(from: from, to: to) }
    var percent: String { "\(max(1, Int((share * 100).rounded())))%" }

    var path: [RepNode] {
        var out: [RepNode] = []
        var n: RepNode? = self
        while let x = n, !x.isRoot { out.insert(x, at: 0); n = x.parent }
        return out
    }
    var ucis: [String] { path.map(\.uci) }

    /// Most specific opening name on the way here.
    var openingName: String? {
        var n: RepNode? = self
        while let x = n { if let o = x.opening { return o }; n = x.parent }
        return nil
    }

    /// Short name: the part after the colon, or the whole name.
    var shortName: String? {
        guard let o = openingName else { return nil }
        return o.components(separatedBy: ": ").last
    }

    /// The moves so far as "1.e4 e5 2.Nf3".
    var moveText: String {
        var s = ""
        for n in path { s += (n.mover == .white ? "\(Chess.moveNumber(n.fenBefore))." : (s.isEmpty ? "\(Chess.moveNumber(n.fenBefore))…" : "")) + n.san + " " }
        return s.trimmingCharacters(in: .whitespaces)
    }
}

/// A group of lines you learn together, e.g. "vs the Sicilian" or "Ponziani: 3…Nf6".
struct Chapter: Identifiable, Hashable {
    let entry: RepNode            // the opponent's move that starts it
    let title: String
    let subtitle: String
    var id: String { entry.id }
    var reach: Double { entry.reach }
    static func == (a: Chapter, b: Chapter) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

final class Repertoire: Identifiable {
    let id: String
    let name: String
    let color: PieceColor
    let summary: String
    let source: String
    /// The moves that define the opening, from the start ("Ponziani": 1.e4 e5 2.Nf3 Nc6 3.c3).
    let setup: [String]
    let title: String
    let family: String
    let blurb: String
    let popularity: Double
    let root: RepNode
    /// Every move you play, most common position first.
    let myMoves: [RepNode]
    let chapters: [Chapter]
    let traps: [RepNode]
    let brilliants: [RepNode]
    private let index: [String: RepNode]
    private let byPosition: [String: RepNode]

    fileprivate init(dto: RepertoireDTO) {
        id = dto.id
        name = dto.name
        color = dto.color == "w" ? .white : .black
        summary = dto.summary
        source = dto.source
        switch dto.id {
        case "white":
            setup = dto.setup ?? ["e2e4", "e7e5", "g1f3", "b8c6", "c2c3"]
            title = dto.title ?? "Ponziani"
            family = dto.family ?? "Open games"
            blurb = dto.blurb ?? "1.e4, then c3 and d4 against 1…e5"
        case "black":
            setup = dto.setup ?? ["e2e4", "c7c6"]
            title = dto.title ?? "Caro-Kann"
            family = dto.family ?? "Vs 1.e4"
            blurb = dto.blurb ?? "…c6 and …d5 against everything"
        default:
            setup = dto.setup ?? []
            title = dto.title ?? dto.name
            family = dto.family ?? ""
            blurb = dto.blurb ?? dto.summary
        }
        popularity = dto.popularity ?? 0
        var index: [String: RepNode] = [:]
        var byPosition: [String: RepNode] = [:]
        var mine: [RepNode] = []
        let me: PieceColor = dto.color == "w" ? .white : .black

        func build(_ d: RepNodeDTO, parentPath: String, fen: String, parent: RepNode?) -> RepNode {
            let path = parentPath.isEmpty ? d.uci : parentPath + "," + d.uci
            let n = RepNode(dto: d, path: path, fenBefore: fen)
            n.parent = parent
            index[path] = n
            let key = Repertoire.key(n.fenAfter)
            // The first node for a position wins, except that a real node always replaces a transposition stub.
            if byPosition[key] == nil || (byPosition[key]!.transposes != nil && n.transposes == nil) { byPosition[key] = n }
            if !n.isRoot && n.mover == me { mine.append(n) }
            n.children = d.children.map { build($0, parentPath: path, fen: n.fenAfter, parent: n) }
                .sorted { $0.share > $1.share }
            return n
        }
        let r = build(dto.tree, parentPath: "", fen: Chess.startFEN, parent: nil)
        root = r
        self.index = index
        self.byPosition = byPosition
        myMoves = mine.sorted { $0.reach > $1.reach }
        traps = index.values.filter(\.isTrap).sorted { $0.reach > $1.reach }
        brilliants = index.values.filter(\.isBrilliant).sorted { $0.reach > $1.reach }
        chapters = Repertoire.makeChapters(root: r, me: me, index: index)
    }

    /// Opponent choices big enough to learn as their own chapter. A very common reply (like 1…e5) is split
    /// one level further so each chapter stays a sensible size.
    /// A transposition stub (a position that continues elsewhere) never becomes a chapter of its own: it would
    /// hold none of your moves and show 0% forever. Only when the real subtree it leads to belongs to no other
    /// chapter does the stub stay, and then the chapter covers that real subtree (see `myMoves(in:)`).
    private static func makeChapters(root: RepNode, me: PieceColor, index: [String: RepNode]) -> [Chapter] {
        var out: [Chapter] = []
        var stubs: [(entry: RepNode, real: RepNode)] = []
        func isStub(_ n: RepNode) -> Bool { n.transposes != nil && n.children.isEmpty }
        func opponentNodes(below n: RepNode) -> [RepNode] {
            // the opponent's replies after my next move (or directly, if it's their turn)
            if n.children.first?.mover == me { return n.children.flatMap { $0.children } }
            return n.children
        }
        func visit(_ n: RepNode, depth: Int) {
            let kids = opponentNodes(below: n).filter { !$0.isRoot }
            for k in kids {
                if isStub(k) {
                    if k.reach >= 0.004, let t = k.transposes, let real = index[t], !isStub(real) {
                        stubs.append((k, real))
                    }
                    continue
                }
                let deeper = opponentNodes(below: k)
                if k.reach > 0.22 && depth < 2 && deeper.count > 1 {
                    visit(k, depth: depth + 1)
                } else if k.reach >= 0.004 {
                    let name = k.shortName ?? k.openingName ?? "After \(k.numbered)"
                    out.append(Chapter(entry: k, title: name, subtitle: k.moveText))
                }
            }
        }
        visit(root, depth: 0)
        func overlaps(_ a: String, _ b: String) -> Bool { a == b || a.hasPrefix(b + ",") || b.hasPrefix(a + ",") }
        var taken = out.map(\.entry.id)
        for (k, real) in stubs where !taken.contains(where: { overlaps($0, real.id) }) {
            let name = k.shortName ?? real.shortName ?? k.openingName ?? "After \(k.numbered)"
            out.append(Chapter(entry: k, title: name, subtitle: k.moveText))
            taken.append(real.id)
        }
        return out.sorted { $0.reach > $1.reach }
    }

    /// Placement and side to move: the same position whatever the move counters (or castling notation) say.
    static func key(_ fen: String) -> String {
        fen.split(separator: " ").prefix(2).joined(separator: " ")
    }

    /// A chapter the opponent steers into before your opening is set up ("could also turn into").
    func isDeviation(_ ch: Chapter) -> Bool {
        let ids = ch.entry.id.split(separator: ",").map(String.init)
        return ids.count <= setup.count && ids != Array(setup.prefix(ids.count))
    }

    /// Where the opening is set up (the last setup move), if the tree has it.
    var setupNode: RepNode? { setup.isEmpty ? nil : index[setup.joined(separator: ",")] }
    var setupFEN: String { setupNode?.fenAfter ?? Chess.startFEN }

    func node(_ id: String) -> RepNode? { index[id] }
    func node(ucis: [String]) -> RepNode? { index[ucis.joined(separator: ",")] }
    /// The repertoire node for a position, whatever move order reached it.
    func node(fen: String) -> RepNode? { byPosition[Repertoire.key(fen)] }

    /// Where play continues from here: follows a transposition to the copy that has children.
    func continuing(_ n: RepNode) -> RepNode {
        if let t = n.transposes, let target = index[t] { return target }
        return n
    }

    /// Your move in this position, if the repertoire has one.
    func myMove(after n: RepNode) -> RepNode? {
        let c = continuing(n)
        return c.children.first { $0.mover == color }
    }

    /// The opponent's known replies here, most common first.
    func replies(after n: RepNode) -> [RepNode] {
        continuing(n).children.filter { $0.mover != color }
    }

    func chapter(containing n: RepNode) -> Chapter? {
        chapters.first { ch in
            let root = continuing(ch.entry).id
            return n.id == ch.entry.id || n.id.hasPrefix(ch.entry.id + ",") || n.id == root || n.id.hasPrefix(root + ",")
        }
    }

    /// Every one of your moves inside a chapter (following a transposition to the real subtree).
    func myMoves(in chapter: Chapter) -> [RepNode] {
        let root = continuing(chapter.entry).id
        return myMoves.filter { $0.id.hasPrefix(root + ",") }
    }

    /// The most common path from this node down to a leaf, following the top reply each time.
    func mainLine(from n: RepNode) -> [RepNode] {
        var out: [RepNode] = []
        var cur = continuing(n)
        while let next = cur.children.first {
            out.append(next)
            cur = continuing(next)
            if out.count > 40 { break }
        }
        return out
    }

    var allNodeCount: Int { index.count }
}

// MARK: - Loading

/// One opening in the library, from library-index.json (the pack itself loads when opened).
struct LibraryEntry: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let color: String
    let family: String?
    let blurb: String?
    let setupSAN: String?
    let setup: [String]?
    let fen: String?
    let popularity: Double?
    var side: PieceColor { color == "w" ? .white : .black }
}

enum RepertoireLoader {
    static let ids = ["white", "black"]

    static func loadIndex() async -> [LibraryEntry] {
        await Task.detached(priority: .utility) {
            let url = Bundle.main.url(forResource: "library-index", withExtension: "json")
                ?? Bundle.main.url(forResource: "library-index", withExtension: "json", subdirectory: "library")
            guard let url, let data = try? Data(contentsOf: url) else { return [] }
            return (try? JSONDecoder().decode([LibraryEntry].self, from: data)) ?? []
        }.value
    }

    /// One repertoire or library pack by id, off the main thread.
    static func load(_ id: String) async -> Repertoire? {
        await Task.detached(priority: .userInitiated) {
            let url = Bundle.main.url(forResource: id, withExtension: "json")
                ?? Bundle.main.url(forResource: id, withExtension: "json", subdirectory: "library")
            guard let url, let data = try? Data(contentsOf: url),
                  let dto = try? JSONDecoder().decode(RepertoireDTO.self, from: data) else { return nil }
            return Repertoire(dto: dto)
        }.value
    }

    /// Decodes both repertoires off the main thread.
    static func loadAll() async -> [Repertoire] {
        await Task.detached(priority: .userInitiated) {
            ids.compactMap { id -> Repertoire? in
                guard let url = Bundle.main.url(forResource: id, withExtension: "json"),
                      let data = try? Data(contentsOf: url),
                      let dto = try? JSONDecoder().decode(RepertoireDTO.self, from: data) else { return nil }
                return Repertoire(dto: dto)
            }
        }.value
    }
}
