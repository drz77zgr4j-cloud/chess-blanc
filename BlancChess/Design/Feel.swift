import UIKit
import AVFoundation

/// Haptics and sound, as v1 had them: the original wooden move clicks and answer sounds,
/// firm move taps, success and error notifications for right and wrong.
@MainActor
enum Feel {
    static var soundOn = true
    static var hapticsOn = true

    private static let selection = UISelectionFeedbackGenerator()
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let notify = UINotificationFeedbackGenerator()
    private static var players: [String: [AVAudioPlayer]] = [:]
    private static var turn: [String: Int] = [:]
    private static var ready = false

    /// Called just after launch (after the first frame): prepares generators and audio so feedback is instant.
    /// A sound asked for before that prepares it on the spot.
    static func prepare() {
        guard !ready else { return }
        ready = true
        // Ambient and mixed: your music keeps playing underneath, and the silent switch silences the app.
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        for name in ["move", "capture", "check", "castle", "right", "wrong", "complete", "next"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else { continue }
            players[name] = (0..<3).compactMap { _ in
                let p = try? AVAudioPlayer(contentsOf: url)
                p?.prepareToPlay()
                return p
            }
        }
        selection.prepare(); light.prepare(); rigid.prepare(); notify.prepare()
    }

    private static func play(_ name: String, volume: Float = 1) {
        guard soundOn else { return }
        if !ready { prepare() }
        guard let list = players[name], !list.isEmpty else { return }
        let i = (turn[name] ?? 0) % list.count
        turn[name] = i + 1
        let p = list[i]
        p.volume = volume
        p.currentTime = 0
        p.play()
    }

    // MARK: Haptics

    /// Chip, tab, button.
    static func tick() { if hapticsOn { selection.selectionChanged() } }
    static func tap() { if hapticsOn { selection.selectionChanged() } }
    static func lift() { if hapticsOn { light.impactOccurred(intensity: 0.8) } }
    static func success() { if hapticsOn { notify.notificationOccurred(.success) } }
    static func warning() { if hapticsOn { notify.notificationOccurred(.warning) } }
    static func error() { if hapticsOn { notify.notificationOccurred(.error) } }

    // MARK: Moments

    /// A move sound picked from the SAN: capture, check, castle or a plain move.
    static func move(san: String) {
        if san.contains("+") || san.contains("#") { play("check") }
        else if san.hasPrefix("O-O") { play("castle") }
        else if san.contains("x") { play("capture") }
        else { play("move") }
        if hapticsOn { (san.contains("x") ? rigid : light).impactOccurred(intensity: 0.8) }
    }

    static func move(capture: Bool = false) { move(san: capture ? "x" : "") }

    static func right() { play("right", volume: 0.7); success() }
    static func wrong() { play("wrong", volume: 0.8); error() }
    static func next() { play("next", volume: 0.6); tick() }
    /// A line learned, a mistake fixed.
    static func gained() { play("right", volume: 0.7); success() }
    /// A session done, a game won, an opening learned.
    static func complete() { play("complete", volume: 0.8); success() }
    static func level() { complete() }
    /// A game lost against the bot.
    static func lost() { play("wrong", volume: 0.6) }
}

/// Old name, kept so the board and engine code read naturally.
typealias Feedback = Feel
