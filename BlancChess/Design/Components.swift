import SwiftUI

// Blanc family components. Sizes follow BNShellComponents.swift exactly.

// MARK: - Ground

/// The place light: a soft radial glow from the top of the screen, in the colour of the place.
struct Spotlight: View {
    var colour: Color = BC.blue
    var strength: Double = 0.3
    var anchor: UnitPoint = UnitPoint(x: 0.5, y: 0.0)
    var body: some View {
        GeometryReader { geo in
            ZStack {
                BC.bg
                RadialGradient(colors: [colour, colour.opacity(0)], center: .center, startRadius: 0, endRadius: 320)
                    .frame(width: 640, height: 640)
                    .position(x: geo.size.width * anchor.x, y: geo.size.height * anchor.y)
                    .opacity(strength)
                    .animation(BC.curve(0.4), value: colour)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// The ground under a sheet: #0C0C0E with a glow rising from the bottom in the colour of what opened it.
struct SheetGround: View {
    var colour: Color = BC.blue
    var body: some View {
        ZStack {
            BC.sheet
            RadialGradient(colors: [colour.opacity(0.34), .clear], center: .bottom, startRadius: 0, endRadius: 360)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Text

/// 12 semibold, uppercase, tracked: section labels and eyebrows.
struct LabelText: View {
    let text: String
    var colour: Color = BC.mute
    init(_ text: String, colour: Color = BC.mute) { self.text = text; self.colour = colour }
    var body: some View {
        Text(text.uppercased()).font(.bcLabel).tracking(0.72).foregroundStyle(colour)
    }
}

// MARK: - Headers

/// Tab root header: 30 bold title with an optional 42 pt circle button.
struct TabHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.bcTabTitle).tracking(-0.6).foregroundStyle(BC.ink)
                if let subtitle { Text(subtitle).font(.bcCaption).foregroundStyle(BC.mute).lineLimit(1) }
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension TabHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) { self.title = title; self.subtitle = subtitle; self.trailing = EmptyView() }
}

/// Pushed-screen nav bar: mute "‹ Back" left, 17 bold title centred, optional trailing control.
struct NavBar<Trailing: View>: View {
    var back: String = "Back"
    let title: String
    var subtitle: String? = nil
    var onBack: (() -> Void)? = nil
    @ViewBuilder var trailing: Trailing
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            VStack(spacing: 1) {
                Text(title).font(.bcNavTitle).foregroundStyle(BC.ink).lineLimit(1).minimumScaleFactor(0.8)
                if let subtitle { Text(subtitle).font(.system(size: 12, weight: .medium)).foregroundStyle(BC.mute).lineLimit(1) }
            }
            .padding(.horizontal, 90)
            HStack {
                Button {
                    Feel.tick()
                    if let onBack { onBack() } else { dismiss() }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold))
                        Text(back).font(.system(size: 15)).lineLimit(1)
                    }
                    .foregroundStyle(BC.mute)
                    .frame(maxWidth: 86, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(back)
                Spacer()
                trailing
            }
        }
        .frame(minHeight: 44)
        .padding(.horizontal, BC.side)
    }
}

extension NavBar where Trailing == EmptyView {
    init(back: String = "Back", title: String, subtitle: String? = nil, onBack: (() -> Void)? = nil) {
        self.back = back; self.title = title; self.subtitle = subtitle; self.onBack = onBack; self.trailing = EmptyView()
    }
}

/// 42 pt round header button: card fill, hairline, 17 semibold glyph.
struct CircleButton: View {
    let systemImage: String
    let label: String
    var badge: Bool = false
    var tint: Color = BC.ink
    let action: () -> Void
    var body: some View {
        Button { Feel.tick(); action() } label: {
            Image(systemName: systemImage).font(.system(size: 17, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(BC.card, in: Circle())
                .overlay(Circle().stroke(BC.line, lineWidth: 1))
                .overlay(alignment: .topTrailing) {
                    if badge { Circle().fill(BC.coral).frame(width: 8, height: 8).offset(x: -6, y: 6) }
                }
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(label)
    }
}

// MARK: - Surfaces

/// Card: #131316, hairline, radius 24, padding 18.
struct CardBox<Content: View>: View {
    var padding: CGFloat = BC.pad
    var radius: CGFloat = BC.rCard
    var border: Color = BC.line
    var fill: Color = BC.card
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(border, lineWidth: 1))
    }
}

/// 40 pt icon tile: raised fill, radius 14, glyph tinted in its kind's colour. Never glowing.
struct IconTile: View {
    let systemImage: String
    var colour: Color = BC.ink
    var size: CGFloat = 40
    var body: some View {
        Image(systemName: systemImage).font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(colour)
            .frame(width: size, height: size)
            .background(BC.raised, in: RoundedRectangle(cornerRadius: BC.rTile, style: .continuous))
    }
}

/// A list row: tile, title over sub, value, chevron. Rows sit in a `RowGroup` with hairlines between them.
struct Row<Leading: View>: View {
    let title: String
    var subtitle: String? = nil
    var value: String? = nil
    var valueColour: Color = BC.mute
    var chevron: Bool = true
    @ViewBuilder var leading: Leading
    var body: some View {
        HStack(spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.bcRowTitle).foregroundStyle(BC.ink).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if let subtitle { Text(subtitle).font(.bcCaption).foregroundStyle(BC.mute).lineLimit(2) }
            }
            Spacer(minLength: 6)
            if let value { Text(value).font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(valueColour) }
            if chevron { Image(systemName: "chevron.forward").font(.system(size: 13, weight: .semibold)).foregroundStyle(BC.mute) }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

extension Row where Leading == EmptyView {
    init(title: String, subtitle: String? = nil, value: String? = nil, valueColour: Color = BC.mute, chevron: Bool = true) {
        self.title = title; self.subtitle = subtitle; self.value = value; self.valueColour = valueColour
        self.chevron = chevron; self.leading = EmptyView()
    }
}

/// Rows in a card, split by hairlines.
struct RowGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            _VariadicView.Tree(HairlineLayout()) { content }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
        .background(BC.card, in: RoundedRectangle(cornerRadius: BC.rCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BC.rCard, style: .continuous).stroke(BC.line, lineWidth: 1))
    }
}

private struct HairlineLayout: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        ForEach(children) { child in
            child
            if child.id != last { Rectangle().fill(BC.line).frame(height: 1) }
        }
    }
}

/// Section label above a group.
struct SectionBox<Content: View>: View {
    let title: String
    var trailing: String? = nil
    var action: (() -> Void)? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                LabelText(title)
                Spacer()
                if let trailing, let action {
                    Button { Feel.tick(); action() } label: {
                        Text(trailing).font(.system(size: 13, weight: .semibold)).foregroundStyle(BC.mute)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)
            content
        }
    }
}

// MARK: - Buttons

/// The press: 0.97 in over 0.09 s, back with a small overshoot.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(configuration.isPressed ? .easeOut(duration: 0.09) : .spring(response: 0.18, dampingFraction: 0.55),
                       value: configuration.isPressed)
    }
}

/// The one white block per screen: 56 tall capsule, black 16 bold label.
struct BlockButton: View {
    let title: String
    var systemImage: String? = nil
    var enabled: Bool = true
    let action: () -> Void
    var body: some View {
        Button {
            guard enabled else { Feel.error(); return }
            Feel.tap()
            action()
        } label: {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 16, weight: .bold)) }
                Text(title).font(.bcBlock).lineLimit(1).minimumScaleFactor(0.75)
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Color.white, in: Capsule())
            .shadow(color: .white.opacity(enabled ? 0.14 : 0), radius: 15, y: 8)
            .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(PressStyle())
    }
}

/// Secondary: same capsule in card fill, hairline, no shadow.
struct SecondaryButton: View {
    let title: String
    var systemImage: String? = nil
    var tint: Color = BC.ink
    var height: CGFloat = 56
    let action: () -> Void
    var body: some View {
        Button { Feel.tick(); action() } label: {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 15, weight: .bold)) }
                Text(title).font(.system(size: 15, weight: .bold)).lineLimit(1).minimumScaleFactor(0.75)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(BC.card, in: Capsule())
            .overlay(Capsule().stroke(BC.line, lineWidth: 1))
        }
        .buttonStyle(PressStyle())
    }
}

/// Quiet action: 14 semibold mute text.
struct QuietButton: View {
    let title: String
    var colour: Color = BC.mute
    let action: () -> Void
    var body: some View {
        Button { Feel.tick(); action() } label: {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(colour)
                .padding(.vertical, 8).padding(.horizontal, 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Small capsule action used inside cards and coach bubbles.
struct PillButton: ButtonStyle {
    var filled: Bool = false
    var tint: Color = BC.ink
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(filled ? .black : tint)
            .padding(.horizontal, 15).frame(height: 38)
            .background(filled ? Color.white : BC.raised, in: Capsule())
            .overlay(Capsule().stroke(filled ? .clear : BC.line, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Chips

/// 38 tall chip. Active = white with black text. A row of chips is also the segmented control.
struct Chip: View {
    let title: String
    var systemImage: String? = nil
    var dot: Color? = nil
    var active: Bool = false
    let action: () -> Void
    var body: some View {
        Button { Feel.tick(); action() } label: {
            HStack(spacing: 5) {
                if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
                if let systemImage { Image(systemName: systemImage).font(.system(size: 12, weight: .semibold)) }
                Text(title).font(.bcChip).lineLimit(1)
            }
            .foregroundStyle(active ? .black : BC.ink)
            .padding(.horizontal, 16).frame(height: 38)
            .background(active ? Color.white : BC.card, in: Capsule())
            .overlay(Capsule().stroke(active ? .clear : BC.line, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// A horizontal row of chips that picks one value.
struct ChipPicker<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    var scrolls: Bool = true
    var body: some View {
        Group {
            if scrolls {
                ScrollView(.horizontal) { row.padding(.horizontal, BC.side) }
                    .scrollIndicators(.hidden)
                    .padding(.horizontal, -BC.side)
            } else {
                row
            }
        }
    }
    private var row: some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.0) { o in
                Chip(title: o.1, active: o.0 == selection) {
                    withAnimation(BC.curve(0.24)) { selection = o.0 }
                }
            }
        }
    }
}

/// Small static label capsule.
struct Tag: View {
    let text: String
    var colour: Color = BC.mute
    var filled: Bool = false
    var body: some View {
        Text(text).font(.system(size: 12, weight: .bold).monospacedDigit())
            .foregroundStyle(filled ? .black : colour)
            .padding(.horizontal, 8).frame(height: 22)
            .background(filled ? colour : colour.opacity(0.14), in: Capsule())
    }
}

// MARK: - Progress

/// Ring pill: 100 × 52 capsule with a progress arc around it; label underneath.
struct RingPill: View {
    let icon: String
    let value: String
    let label: String
    var colour: Color = BC.blue
    var progress: Double = 0
    @State private var drawn = false
    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                CapsulePerimeter().fill(BC.card)
                CapsulePerimeter().stroke(Color.white.opacity(0.08), lineWidth: 2.5)
                CapsulePerimeter()
                    .trim(from: 0, to: drawn ? Self.arc(progress) : Self.arc(0))
                    .stroke(colour, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .shadow(color: colour.opacity(0.7), radius: 6)
                    .animation(BC.curve(0.6), value: progress)
                HStack(spacing: 4) {
                    Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(BC.ink)
                    Text(value).font(.bcPill).tracking(-0.19).foregroundStyle(BC.ink)
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .contentTransition(.numericText())
                }
                .padding(.horizontal, 12)
            }
            .frame(minWidth: 100, maxWidth: 150)
            .frame(height: 52)
            .frame(maxWidth: .infinity)
            Text(label).font(.system(size: 13)).foregroundStyle(BC.mute).lineLimit(1).minimumScaleFactor(0.8)
        }
        .onAppear {
            guard !drawn else { return }
            withAnimation(BC.curve(0.6).delay(0.3)) { drawn = true }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(value)")
    }

    /// The share of the perimeter drawn, with a short tick at nought to show where it starts.
    static func arc(_ p: Double) -> Double { max(p.isFinite ? min(max(p, 0), 1) : 0, 0.012) }
}

/// A capsule's outline from the left end of its top edge, clockwise: where a ring pill's arc starts.
struct CapsulePerimeter: Shape {
    func path(in rect: CGRect) -> Path {
        let r = min(rect.height, rect.width) / 2
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.midY), radius: r, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + r, y: rect.midY), radius: r, startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
        return path
    }
}

/// 8 tall capsule bar.
struct ProgressBar: View {
    let value: Double
    var colour: Color = BC.mint
    var height: CGFloat = 8
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                if value > 0 {
                    Capsule().fill(colour).frame(width: max(height, geo.size.width * min(1, value)))
                }
            }
        }
        .frame(height: height)
        .animation(BC.curve(0.9), value: value)
    }
}

/// Stat card: label, 24 bold number, mute context.
struct StatCard: View {
    let label: String
    let value: String
    var context: String? = nil
    var colour: Color = BC.ink
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabelText(label)
            Text(value).font(.bcStat).tracking(-0.44).foregroundStyle(colour).lineLimit(1).minimumScaleFactor(0.6)
            if let context { Text(context).font(.system(size: 12)).foregroundStyle(BC.mute).lineLimit(1) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .background(BC.card, in: RoundedRectangle(cornerRadius: BC.rRow, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BC.rRow, style: .continuous).stroke(BC.line, lineWidth: 1))
    }
}

// MARK: - Chess bits

/// The round move-mark badge.
struct ClassBadge: View {
    let cls: MoveClass
    var size: CGFloat = 22
    var body: some View {
        Text(cls.symbol)
            .font(.system(size: size * (cls.symbol.count > 1 && cls.symbol.unicodeScalars.first!.isASCII ? 0.42 : 0.5), weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(cls.colour, in: Circle())
            .overlay(Circle().stroke(.black.opacity(0.25), lineWidth: 1))
            .accessibilityLabel(cls.title)
    }
}

/// Vertical-free eval bar: white share from the left, the number on the winning side.
struct EvalBar: View {
    let cp: Double?
    let mate: Int?
    var height: CGFloat = 22
    var body: some View {
        let share = Eval.whiteShare(cp: cp, mate: mate)
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color(hex: 0x403D39))
                Rectangle().fill(Color(hex: 0xF0F0F0)).frame(width: geo.size.width * share)
                HStack {
                    if share >= 0.5 {
                        Text(Eval.text(cp: cp, mate: mate)).foregroundStyle(.black)
                        Spacer()
                    } else {
                        Spacer()
                        Text(Eval.text(cp: cp, mate: mate)).foregroundStyle(.white)
                    }
                }
                .font(.system(size: 12, weight: .heavy).monospacedDigit())
                .padding(.horizontal, 8)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .animation(BC.curve(0.5), value: share)
        .accessibilityLabel("Evaluation \(Eval.text(cp: cp, mate: mate))")
    }
}

/// Bottom board toolbar button.
struct ToolbarButton: View {
    let title: String
    let systemImage: String
    var tint: Color = BC.ink
    var enabled: Bool = true
    let action: () -> Void
    var body: some View {
        Button { Feel.tick(); action() } label: {
            VStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 19, weight: .medium)).frame(height: 22)
                Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(enabled ? tint : BC.mute.opacity(0.4))
            .frame(maxWidth: .infinity, minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

struct BoardToolbar<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 0) { content }
            .padding(.horizontal, 6)
            .background(BC.sheet.opacity(0.92))
            .overlay(alignment: .top) { Rectangle().fill(BC.line).frame(height: 1) }
    }
}

// MARK: - Empty

/// An empty screen is a card with one action, never a spinner.
struct EmptyCard: View {
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        CardBox {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.bcCardTitle).foregroundStyle(BC.ink)
                Text(message).font(.bcBody).foregroundStyle(BC.mute).fixedSize(horizontal: false, vertical: true)
                if let actionTitle, let action {
                    BlockButton(title: actionTitle, action: action).padding(.top, 6)
                }
            }
        }
    }
}

// MARK: - Sheets

/// Sheet chrome: grab handle, 24 bold title, Done.
struct SheetChrome<Content: View>: View {
    let title: String
    var colour: Color = BC.blue
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule().fill(Color.white.opacity(0.22)).frame(width: 36, height: 5)
                .frame(maxWidth: .infinity).padding(.top, 10)
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.bcSheetTitle).foregroundStyle(BC.ink)
                Spacer()
                Button("Done") { dismiss() }.font(.system(size: 15)).foregroundStyle(BC.mute)
            }
            .padding(.horizontal, BC.side).padding(.top, 14)
            content
                .padding(.horizontal, BC.side).padding(.top, 14).padding(.bottom, 22)
        }
        .background(SheetGround(colour: colour))
        .presentationCornerRadius(BC.rSheet)
        .presentationDragIndicator(.hidden)
        .presentationBackground(BC.sheet)
    }
}

// MARK: - Toast

/// White capsule toast, answers a tap only. Gone after 1.6 s.
struct Toast: Equatable {
    var symbol: String
    var text: String
}

struct ToastLayer: ViewModifier {
    @Binding var toast: Toast?
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let t = toast {
                HStack(spacing: 8) {
                    Image(systemName: t.symbol).font(.system(size: 13, weight: .bold))
                    Text(t.text).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 16).frame(height: 40)
                .background(Color.white, in: Capsule())
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: t) {
                    try? await Task.sleep(nanoseconds: 1_600_000_000)
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { toast = nil }
                }
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: toast)
    }
}

extension View {
    func toast(_ toast: Binding<Toast?>) -> some View { modifier(ToastLayer(toast: toast)) }

    /// Blanc's arrive: rise 14 pt and settle, staggered by index.
    func arrive(_ index: Int = 0) -> some View { modifier(Arrive(index: index)) }

    /// Content that scrolls under the clock fades out instead of colliding with it. A mask on the
    /// scrolling content only, so the place's glow behind it is never dimmed.
    func topFade() -> some View {
        mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: 74)
                Color.black
            }
            .ignoresSafeArea()
        }
    }
}

private struct Arrive: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 14)
            .scaleEffect(shown || reduceMotion ? 1 : 0.98, anchor: .top)
            .onAppear {
                guard !shown else { return }
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : BC.curve(0.42).delay(Double(min(index, 8)) * 0.07)) { shown = true }
            }
    }
}
