import SwiftUI

/// Fully rounded pill buttons.
struct PillButtonStyle: ButtonStyle {
    enum Kind {
        /// Off-white fill, dark text: the main call to action.
        case primary
        /// 12% tint fill, 50% tint border, light tint label (Delete / Keep).
        case tinted(Tint)
        /// Solid coral, dark text: destructive actions.
        case destructive
        /// Raised surface with a hairline border.
        case secondary
    }

    var kind: Kind = .primary
    var height: CGFloat = Metrics.minTouch
    var font: Font = .buttonLabel

    /// Space on each side of the label: 45% of the pill's height, at least 16pt, in whole points
    /// (20pt for a 44pt pill, 25pt for a 56pt one). Whole points keep the label on the pixel
    /// grid, so a pill laid out at its ideal width never cuts its label short.
    static func horizontalPadding(forHeight height: CGFloat) -> CGFloat {
        max(16, (height * 0.45).rounded())
    }

    func makeBody(configuration: Configuration) -> some View {
        PillButtonBody(configuration: configuration, kind: kind, height: height, font: font)
    }
}

private struct PillButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: PillButtonStyle.Kind
    let height: CGFloat
    let font: Font
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(font)
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, PillButtonStyle.horizontalPadding(forHeight: height))
            .frame(minHeight: height)
            .background(Capsule().fill(background))
            .overlay(Capsule().strokeBorder(border, lineWidth: 1))
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch kind {
        case .primary, .destructive: Palette.ink
        case .tinted(let tint): tint.label
        case .secondary: Palette.text
        }
    }

    private var background: Color {
        switch kind {
        case .primary: Palette.text
        case .destructive: Palette.coral
        case .tinted(let tint): tint.fill
        case .secondary: Palette.raised
        }
    }

    private var border: Color {
        switch kind {
        case .primary, .destructive: .clear
        case .tinted(let tint): tint.border
        case .secondary: Palette.hairlineStrong
        }
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static func pill(_ kind: PillButtonStyle.Kind = .primary, height: CGFloat = Metrics.minTouch, font: Font = .buttonLabel) -> PillButtonStyle {
        PillButtonStyle(kind: kind, height: height, font: font)
    }
}

/// Text buttons in the top bars ("‹ Albums", Undo): no chrome, at least 44×44.
struct BarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BarButtonBody(configuration: configuration)
    }
}

private struct BarButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.buttonLabel)
            .lineLimit(1)
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 10)
            .frame(minWidth: Metrics.minTouch, minHeight: Metrics.minTouch)
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.55 : 1) : 0.35)
    }
}

extension ButtonStyle where Self == BarButtonStyle {
    static var bar: BarButtonStyle { BarButtonStyle() }
}

/// "‹ Albums" style back button. Where a top bar is short of room it can show the chevron alone;
/// VoiceOver still reads the title.
struct BackButton: View {
    let title: String
    var showsTitle = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                if showsTitle {
                    Text(title)
                }
            }
        }
        .buttonStyle(.bar)
        .accessibilityLabel(title)
        .accessibilityHint("Goes back")
    }
}
