import SwiftUI

/// Blanc Chess tokens. Same family as Blanc Notes (BNShellTokens.swift, RULEBOOK.md):
/// pure black ground, one meaning per colour, SF Pro, one white block per screen.
enum BC {
    // Ground and surfaces
    static let bg = Color.black
    static let card = Color(hex: 0x131316)
    static let raised = Color(hex: 0x1B1B1F)
    static let raised2 = Color(hex: 0x24242A)
    static let sheet = Color(hex: 0x0C0C0E)
    static let ink = Color(hex: 0xF5F5F7)
    static let mute = Color(hex: 0xABABB0)
    static let faint = Color(hex: 0x6E6E74)
    static let line = Color.white.opacity(0.06)
    static let glass = Color(hex: 0x1C1C20, opacity: 0.75)

    // One meaning per colour (RULEBOOK §1)
    static let mint = Color(hex: 0x5CE0A5)    // right, won, learned, done
    static let coral = Color(hex: 0xFF6B6B)   // needs you: wrong, missed, lost
    static let amber = Color(hex: 0xFFB454)   // your best, the streak
    static let blue = Color(hex: 0x5EB8FF)    // train
    static let violet = Color(hex: 0x8C7BFF)  // analysis / the engine
    static let gold = Color(hex: 0xF5C542)

    // Move marks: standard chess annotation, in Chess Blanc's own tones
    static let teal = Color(hex: 0x3DD9C1)    // brilliant
    static let great = Color(hex: 0x5EB8FF)   // only move
    static let best = Color(hex: 0x6FD48A)    // best
    static let excellent = Color(hex: 0x9ED67A)
    static let good = Color(hex: 0xA9B8A0)
    static let book = Color(hex: 0xB79C7E)
    static let inaccuracy = Color(hex: 0xFFD166)
    static let mistake = Color(hex: 0xFF9F5A)
    static let miss = Color(hex: 0xFF7A8A)
    static let blunder = Color(hex: 0xFF4D4D)

    // Board
    static var lightSquare: Color { BoardTheme.current.light }
    static var darkSquare: Color { BoardTheme.current.dark }
    static var lastMove: Color { BoardTheme.current.highlight }
    static let arrow = Color(hex: 0x5FB4D8)

    // Space and shape (points)
    static let side: CGFloat = 20
    static let top: CGFloat = 26
    static let gap: CGFloat = 16
    static let pad: CGFloat = 18
    static let rCard: CGFloat = 24
    static let rRow: CGFloat = 20
    static let rBlock: CGFloat = 28
    static let rChip: CGFloat = 19
    static let rSheet: CGFloat = 30
    static let rTile: CGFloat = 14
    static let dockClearance: CGFloat = 100

    /// Blanc Notes' one curve.
    static let curve = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.42)
    static func curve(_ d: Double) -> Animation { .timingCurve(0.2, 0.8, 0.2, 1, duration: d) }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

extension Font {
    static let bcTabTitle = Font.system(size: 30, weight: .bold)
    static let bcGreeting = Font.system(size: 20, weight: .bold)
    static let bcSheetTitle = Font.system(size: 24, weight: .bold)
    static let bcCardTitle = Font.system(size: 17, weight: .bold)
    static let bcNavTitle = Font.system(size: 17, weight: .bold)
    static let bcRowTitle = Font.system(size: 16, weight: .semibold)
    static let bcBody = Font.system(size: 15)
    static let bcBodyStrong = Font.system(size: 15, weight: .semibold)
    static let bcChip = Font.system(size: 14, weight: .semibold)
    static let bcCaption = Font.system(size: 13)
    static let bcLabel = Font.system(size: 12, weight: .semibold)
    static let bcBlock = Font.system(size: 16, weight: .bold)
    static let bcPill = Font.system(size: 22, weight: .bold).monospacedDigit()
    static let bcStat = Font.system(size: 24, weight: .bold).monospacedDigit()
    static let bcRing = Font.system(size: 44, weight: .bold).monospacedDigit()
    static let bcHero = Font.system(size: 36, weight: .bold)
}

/// Marks for each move, in standard chess annotation.
enum MoveClass: String, Codable, CaseIterable, Identifiable {
    case brilliant, great, best, excellent, good, book, inaccuracy, mistake, miss, blunder, forced
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .brilliant: "!!"
        case .great: "!"
        case .best: "◆"
        case .excellent: "+"
        case .good: "✓"
        case .book: "≡"
        case .inaccuracy: "?!"
        case .mistake: "?"
        case .miss: "⊘"
        case .blunder: "??"
        case .forced: "→"
        }
    }

    var colour: Color {
        switch self {
        case .brilliant: BC.teal
        case .great: BC.great
        case .best: BC.best
        case .excellent: BC.excellent
        case .good: BC.good
        case .book: BC.book
        case .inaccuracy: BC.inaccuracy
        case .mistake: BC.mistake
        case .miss: BC.miss
        case .blunder: BC.blunder
        case .forced: BC.good
        }
    }

    var title: String {
        switch self {
        case .brilliant: "Brilliant"
        case .great: "Only move"
        case .best: "Best"
        case .excellent: "Excellent"
        case .good: "Good"
        case .book: "Theory"
        case .inaccuracy: "Inaccuracy"
        case .mistake: "Mistake"
        case .miss: "Missed chance"
        case .blunder: "Blunder"
        case .forced: "Forced"
        }
    }

    /// "Nf3 is the best move", "Bg5 is an inaccuracy".
    var phrase: String {
        switch self {
        case .brilliant: "brilliant"
        case .great: "the only good move"
        case .best: "the best move"
        case .excellent: "excellent"
        case .good: "good"
        case .book: "opening theory"
        case .inaccuracy: "an inaccuracy"
        case .mistake: "a mistake"
        case .miss: "a missed chance"
        case .blunder: "a blunder"
        case .forced: "forced"
        }
    }

    var isError: Bool { [.mistake, .miss, .blunder].contains(self) }
    var isSlip: Bool { [.inaccuracy, .mistake, .miss, .blunder].contains(self) }
    var isTop: Bool { [.brilliant, .great, .best].contains(self) }

    /// Best to worst.
    static let reviewOrder: [MoveClass] = [.brilliant, .great, .best, .excellent, .good, .book, .inaccuracy, .mistake, .miss, .blunder]
}


/// The board's colours. Picked on the You page; every board and thumbnail draws with the current one.
struct BoardTheme: Identifiable, Equatable {
    let id: String
    let name: String
    let light: Color
    let dark: Color
    let highlight: Color

    private static func hl(_ hex: UInt32, _ a: Double = 0.72) -> Color { Color(hex: hex, opacity: a) }

    static let all: [BoardTheme] = [
        BoardTheme(id: "wood", name: "Wood", light: Color(hex: 0xEDD6B0), dark: Color(hex: 0xB88762), highlight: hl(0xF6D23C)),
        BoardTheme(id: "green", name: "Green", light: Color(hex: 0xE9EDD3), dark: Color(hex: 0x6E9455), highlight: hl(0xF5F682, 0.8)),
        BoardTheme(id: "brown", name: "Brown", light: Color(hex: 0xF0D9B5), dark: Color(hex: 0xB58863), highlight: hl(0xCDD26A, 0.85)),
        BoardTheme(id: "blue", name: "Blue", light: Color(hex: 0xDEE3E6), dark: Color(hex: 0x8CA2AD), highlight: hl(0x9BC7E8, 0.85)),
        BoardTheme(id: "ice", name: "Ice", light: Color(hex: 0xE8F1F8), dark: Color(hex: 0x7FA3C4), highlight: hl(0xA8E0F0, 0.85)),
        BoardTheme(id: "mint", name: "Mint", light: Color(hex: 0xE4F3EA), dark: Color(hex: 0x6FAE8C), highlight: hl(0xF2E27A, 0.85)),
        BoardTheme(id: "purple", name: "Purple", light: Color(hex: 0xEADFF2), dark: Color(hex: 0x8B70AD), highlight: hl(0xF3C7F0, 0.8)),
        BoardTheme(id: "coral", name: "Coral", light: Color(hex: 0xF8E4DA), dark: Color(hex: 0xD48A76), highlight: hl(0xF6D23C)),
        BoardTheme(id: "slate", name: "Slate", light: Color(hex: 0xD3D8DE), dark: Color(hex: 0x6B7685), highlight: hl(0x8FD3B6, 0.8)),
        BoardTheme(id: "blanc", name: "Blanc", light: Color(hex: 0xC8C8CE), dark: Color(hex: 0x5E5E66), highlight: hl(0x5CE0A5, 0.6)),
        BoardTheme(id: "walnut", name: "Walnut", light: Color(hex: 0xD9B98C), dark: Color(hex: 0x7A5233), highlight: hl(0xF6D23C)),
        BoardTheme(id: "marble", name: "Marble", light: Color(hex: 0xF2F0EC), dark: Color(hex: 0xA8A29A), highlight: hl(0xE8C66A, 0.8)),
    ]

    /// Set by the settings (ProgressStore applies it at launch and on every change).
    nonisolated(unsafe) static var current: BoardTheme = all[0]
    static func named(_ id: String) -> BoardTheme { all.first { $0.id == id } ?? all[0] }
}


/// The pieces' artwork. "classic" is the original set; the others are open-licence sets from Lichess.
struct PieceSet: Identifiable, Equatable {
    let id: String
    let name: String
    let credit: String

    static let all: [PieceSet] = [
        PieceSet(id: "classic", name: "Classic", credit: "Colin M.L. Burnett · GPLv2+"),
        PieceSet(id: "merida", name: "Merida", credit: "Armando Hernandez Marroquin · GPLv2+"),
        PieceSet(id: "chessnut", name: "Chessnut", credit: "Alexis Luengas · Apache 2.0"),
        PieceSet(id: "fantasy", name: "Fantasy", credit: "Maurizio Monge · MIT"),
        PieceSet(id: "celtic", name: "Celtic", credit: "Maurizio Monge · MIT"),
        PieceSet(id: "spatial", name: "Spatial", credit: "Maurizio Monge · MIT"),
        PieceSet(id: "papercut", name: "Papercut", credit: "Nikolay Anzarov · CC BY 4.0"),
        PieceSet(id: "totoy", name: "Totoy", credit: "Kosal Sen · CC BY 4.0"),
    ]

    nonisolated(unsafe) static var current: PieceSet = all[0]
    static func named(_ id: String) -> PieceSet { all.first { $0.id == id } ?? all[0] }

    /// Asset name for a piece like "wN".
    func image(_ piece: String) -> String { id == "classic" ? "piece-\(piece)" : "piece-\(id)-\(piece)" }
    static func image(_ piece: String) -> String { current.image(piece) }
}


/// The current board colours and piece set as one value: boards keep it as an input so a change redraws them.
enum BoardLook {
    static var current: String { BoardTheme.current.id + "/" + PieceSet.current.id }
}
