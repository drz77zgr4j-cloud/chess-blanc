import SwiftUI

// Small pieces shared by the Openings screens. Everything here lives in the Openings folder on purpose:
// the foundation stays untouched.

extension RepNode {
    /// A one-line reason for a move when the repertoire has no note.
    var whyLine: String {
        if let note, !note.isEmpty { return note }
        switch why {
        case "theory": return "The main line. Strong players choose it here."
        case "yours": return "Your own choice from your games, and it holds up."
        case "popular": return "The club favourite here, and it scores well."
        case "engine": return "Stockfish's pick in this position."
        default: return "The repertoire move in this position."
        }
    }

    /// The moves so far, trimmed from the front so it fits a nav subtitle.
    func moveTextTail(_ maxChars: Int = 28) -> String {
        let full = moveText
        guard full.count > maxChars else { return full.isEmpty ? "Starting position" : full }
        var tokens = full.split(separator: " ").map(String.init)
        while tokens.count > 1 && tokens.joined(separator: " ").count > maxChars - 2 { tokens.removeFirst() }
        // Don't start on a bare black move without its number.
        if let first = tokens.first, first.first?.isNumber == false, tokens.count > 1 { tokens.removeFirst() }
        return "… " + tokens.joined(separator: " ")
    }

    /// Is this node inside the subtree that starts at `id` ("" = everything)?
    func isUnder(_ id: String) -> Bool {
        id.isEmpty || self.id == id || self.id.hasPrefix(id + ",")
    }
}

extension Repertoire {
    /// A node title for headers: the short opening name, or the repertoire. Kept short enough for a nav bar.
    func title(for n: RepNode) -> String {
        guard let name = n.shortName else { return color == .white ? "White repertoire" : "Black repertoire" }
        return OpeningText.short(name)
    }

    /// Your moves in the subtree that starts at `id` ("" = the whole repertoire).
    func myMoves(under id: String) -> [RepNode] {
        id.isEmpty ? myMoves : myMoves.filter { $0.isUnder(id) }
    }
}

enum OpeningText {
    /// "in 4 hours", "tomorrow", "in 3 days".
    static func until(_ date: Date, from now: Date = Date()) -> String {
        let s = date.timeIntervalSince(now)
        if s <= 60 { return "now" }
        if s < 3600 { return "in \(max(1, Int(s / 60))) min" }
        if s < 20 * 3600 {
            let h = Int((s / 3600).rounded())
            return h == 1 ? "in an hour" : "in \(h) hours"
        }
        let days = Int((s / 86_400).rounded())
        if days <= 1 { return "tomorrow" }
        if days < 14 { return "in \(days) days" }
        if days < 60 { return "in \(days / 7) weeks" }
        return "in \(days / 30) months"
    }

    /// "Jaenisch Counterattack" -> "Jaenisch": names that fit a nav bar.
    static func short(_ name: String, max: Int = 20) -> String {
        guard name.count > max else { return name }
        let filler: Set<String> = ["Variation", "Opening", "Defense", "Defence", "Counterattack", "Attack", "Game", "System", "Line"]
        var words = name.split(separator: " ").map(String.init)
        while words.count > 1, words.joined(separator: " ").count > max, let last = words.last, filler.contains(last) {
            words.removeLast()
        }
        while words.count > 1, words.joined(separator: " ").count > max { words.removeLast() }
        return words.joined(separator: " ")
    }

    /// Chapter titles that tell apart chapters sharing a name: "Ponziani · 3…a6".
    static func distinctTitles(_ chapters: [Chapter]) -> [String: String] {
        var count: [String: Int] = [:]
        for c in chapters { count[c.title, default: 0] += 1 }
        let filler: Set<String> = ["Variation", "Opening", "Defense", "Defence", "Game", "System"]
        var out: [String: String] = [:]
        for c in chapters {
            guard (count[c.title] ?? 0) > 1 else { out[c.id] = c.title; continue }
            var words = c.title.split(separator: " ").map(String.init)
            while words.count > 1, let last = words.last, filler.contains(last) { words.removeLast() }
            out[c.id] = words.joined(separator: " ") + " · " + c.entry.numbered
        }
        return out
    }

    static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    /// "2% of club games", "under 1% of club games".
    static func clubShare(_ share: Double) -> String {
        share < 0.005 ? "under 1% of club games" : "\(Int((share * 100).rounded()))% of club games"
    }
}

/// When a move comes back next, across the given repertoires.
@MainActor
func nextReview(_ reps: [Repertoire], progress: ProgressStore) -> Date? {
    let now = Date()
    var best: Date?
    for rep in reps {
        for n in rep.myMoves {
            let m = progress.memory(rep, n)
            guard m.level > 0, let d = m.due, d > now else { continue }
            if best == nil || d < best! { best = d }
        }
    }
    return best
}

/// The thin win / draw / loss bar under a reply, from your side of the board.
struct ResultsBar: View {
    let results: [Double]?
    let me: PieceColor
    var body: some View {
        GeometryReader { geo in
            let r = results ?? []
            if r.count == 3 {
                let total = max(0.0001, r[0] + r[1] + r[2])
                let win = (me == .white ? r[0] : r[2]) / total
                let draw = r[1] / total
                HStack(spacing: 1.5) {
                    Capsule().fill(BC.mint).frame(width: max(2, geo.size.width * win))
                    if draw > 0.01 { Capsule().fill(BC.faint).frame(width: max(2, geo.size.width * draw)) }
                    Capsule().fill(BC.coral)
                }
            } else {
                Capsule().fill(Color.white.opacity(0.08))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

/// The memory state of one of your moves as a small dot: coral when due.
struct StateDot: View {
    let state: MemoryState
    var due: Bool = false
    var size: CGFloat = 8
    var body: some View {
        Group {
            if due {
                Circle().fill(BC.coral)
            } else if state == .new {
                Circle().stroke(BC.faint, lineWidth: 1.5)
            } else {
                Circle().fill(state.colour)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(due ? "Due" : state.label)
    }
}

/// The tappable breadcrumb from the start to here.
struct OpeningMoveStrip: View {
    struct Item: Identifiable {
        let id: String
        let text: String
        var offBook = false
    }
    let items: [Item]
    let current: String
    let tap: (String) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(items) { item in
                        let on = item.id == current
                        Button {
                            Feel.tick()
                            tap(item.id)
                        } label: {
                            Text(item.text)
                                .font(.system(size: 13, weight: on ? .bold : .semibold).monospacedDigit())
                                .foregroundStyle(on ? Color.black : (item.offBook ? BC.coral : BC.mute))
                                .padding(.horizontal, 9).frame(height: 28)
                                .background(on ? (item.offBook ? BC.coral : Color.white) : BC.card, in: Capsule())
                                .overlay(Capsule().stroke(on ? .clear : BC.line, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .id(item.id)
                    }
                }
                .padding(.horizontal, BC.side)
            }
            .scrollIndicators(.hidden)
            .onAppear { proxy.scrollTo(current, anchor: .trailing) }
            .onChange(of: current) { _, c in
                withAnimation(BC.curve(0.3)) { proxy.scrollTo(c, anchor: .center) }
            }
        }
        .frame(height: 36)
    }
}

/// Stockfish's verdict on a move.
struct MoveJudgement {
    let verdict: Eval.Verdict
    let best: [EngineLine]       // MultiPV before the move
    let after: EngineLine?       // best line after the move

    var bestMove: String? { best.first?.best }
    /// The best reply to the move that was played.
    var bestReply: String? { after?.best }
}

enum Judge {
    /// Classifies `uci` played from `fen` with a quick multipv-2 search and a search of the position after it.
    /// `stillWanted` is checked between the searches (and after them), so a screen that moved on never waits
    /// for, or receives, a stale verdict. The surrounding task's cancellation is honoured the same way.
    @MainActor
    static func move(_ uci: String, from fen: String, isBook: Bool, depth: Int = 14, owner: String,
                     stillWanted: @MainActor () -> Bool = { true }) async -> MoveJudgement? {
        guard let ply = Chess.play(uci, on: fen) else { return nil }
        guard !Task.isCancelled, stillWanted() else { return nil }
        let best = await EngineService.shared.analyse(fen: fen, depth: depth, multipv: 2, owner: owner)
        guard !best.isEmpty, !Task.isCancelled, stillWanted() else { return nil }
        let after: EngineLine?
        switch Chess.outcome(ply.fenAfter) {
        case .checkmate, .draw:
            after = nil
        default:
            after = await EngineService.shared.analyse(fen: ply.fenAfter, depth: max(8, depth - 2), multipv: 1, owner: owner).first
            guard !Task.isCancelled, stillWanted() else { return nil }
        }
        let ctx = Eval.Context(fenBefore: fen, fenAfter: ply.fenAfter, mover: Chess.sideToMove(fen), played: ply.uci,
                               best: best, after: after, isBook: isBook, opponentLoss: nil)
        return MoveJudgement(verdict: Eval.classify(ctx), best: best, after: after)
    }
}

/// How often club players choose `uci` from `fen`, if the book knows the position.
@MainActor
func clubShare(of uci: String, at fen: String, book: OpeningBook?) -> Double? {
    guard let e = book?.entry(fen) else { return nil }
    guard let target = Chess.play(uci, on: fen) else { return nil }
    let key = Chess.placementKey(target.fenAfter)
    for m in e.moves {
        if let p = Chess.play(m.uci, on: fen), Chess.placementKey(p.fenAfter) == key { return e.share(m) }
    }
    return 0
}


/// How far into an opening new moves come from: the main lines first, then deeper, then everything.
enum StudyDepth: Int, CaseIterable, Identifiable {
    case main, deeper, all
    var id: Int { rawValue }
    var title: String { ["Main lines", "Deeper", "Everything"][rawValue] }
    /// Smallest share of your games a position must reach to be taught.
    var minReach: Double { [0.02, 0.005, 0][rawValue] }

    static func of(_ repID: String) -> StudyDepth {
        StudyDepth(rawValue: UserDefaults.standard.integer(forKey: "bc.depth." + repID)) ?? .main
    }
    static func set(_ d: StudyDepth, for repID: String) {
        UserDefaults.standard.set(d.rawValue, forKey: "bc.depth." + repID)
    }
}
