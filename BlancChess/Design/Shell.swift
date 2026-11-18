import SwiftUI

// The Blanc Notes home pieces, ported from BNShellKit / BNHomeView: the character tile, today's tiles,
// the piece row with its picture.

/// Your picture in a rounded square with a soft glow behind it (BNShellCharacter).
/// Your chess.com avatar when there is one, otherwise a white knight.
struct AvatarTile: View {
    var image: UIImage?
    var size: CGFloat = 44
    var glow: Color = BC.amber

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
        ZStack {
            shape.fill(BC.raised)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(shape)
            } else {
                Image("piece-wN").resizable().scaledToFit()
                    .frame(width: size * 0.7, height: size * 0.7)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
            }
        }
        .frame(width: size, height: size)
        .overlay(shape.strokeBorder(glow.opacity(0.9), lineWidth: 1))
        .background {
            shape.fill(glow.opacity(size >= 56 ? 0.73 : 0.53))
                .blur(radius: size * (size >= 56 ? 0.3 : 0.2))
        }
        .accessibilityHidden(true)
    }
}

/// One of today's three tiles: icon, two-word title, a short line. Done ones go mint (BNHomeMissionCard).
struct QuestTile: View {
    let icon: String
    let title: String
    let line: String
    var done = false
    var colour: Color = BC.ink

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: done ? "checkmark.circle.fill" : icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(done ? BC.mint : colour)
                .frame(height: 22)
            Spacer(minLength: 10)
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(done ? BC.ink.opacity(0.6) : BC.ink)
                .lineLimit(2).minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
            Text(line)
                .font(.system(size: 13))
                .foregroundStyle(done ? BC.mint : BC.mute)
                .lineLimit(1).minimumScaleFactor(0.8)
                .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 96, maxHeight: .infinity, alignment: .topLeading)
        .background(BC.card, in: RoundedRectangle(cornerRadius: BC.rRow, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BC.rRow, style: .continuous)
            .strokeBorder(done ? BC.mint.opacity(0.35) : BC.line, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: BC.rRow, style: .continuous))
    }
}

/// A row with a picture on the left (BNShellPieceRow): 76 × 54 picture, title, a dot and a short sub, trailing control.
struct PictureRow<Picture: View, Trailing: View>: View {
    let title: String
    var sub: String? = nil
    var dot: Color? = nil
    @ViewBuilder var picture: Picture
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 14) {
            picture
                .frame(width: 76, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 17, weight: .bold)).foregroundStyle(BC.ink)
                    .lineLimit(1).minimumScaleFactor(0.8)
                if let sub {
                    HStack(spacing: 6) {
                        if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
                        Text(sub).font(.system(size: 14)).foregroundStyle(BC.mute).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 6)
            trailing
        }
        .padding(10)
        .padding(.trailing, 4)
        .background(BC.card, in: RoundedRectangle(cornerRadius: BC.rRow, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BC.rRow, style: .continuous).stroke(BC.line, lineWidth: 1))
        .contentShape(Rectangle())
    }
}

/// A small outlined pill with a glyph and a word ("Practise"), for a row's trailing action.
struct RowAction: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void
    var body: some View {
        Button { Feel.tick(); action() } label: {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 13, weight: .semibold)) }
                Text(title).font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(BC.ink)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(BC.raised, in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
        }
        .buttonStyle(PressStyle())
    }
}

/// A 36 pt round glass button laid over a picture (the hero card's corners).
struct GlassCircle: View {
    let systemImage: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button { Feel.tick(); action() } label: {
            Image(systemName: systemImage).font(.system(size: 14, weight: .bold)).foregroundStyle(.black)
                .frame(width: 36, height: 36)
                .background(Color.white, in: Circle())
                .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(label)
    }
}

extension DayText {
    /// "Good afternoon, Sam" — the first word of a name only.
    static func greeting(name: String?) -> String {
        guard let first = name?.split(separator: " ").first, !first.isEmpty else { return greeting }
        return "\(greeting), \(first)"
    }
}
