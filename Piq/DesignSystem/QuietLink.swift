import SwiftUI

/// A text link in muted type with a small trailing arrow, for a quiet way out of the app
/// ("Connected to Photos ↗"): it brightens while pressed and is at least 44pt tall.
struct QuietLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.meta)
            .lineLimit(1)
            .foregroundStyle(configuration.isPressed ? Palette.text : Palette.textMuted)
            .frame(minWidth: Metrics.minTouch, minHeight: Metrics.minTouch)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == QuietLinkButtonStyle {
    static var quietLink: QuietLinkButtonStyle { QuietLinkButtonStyle() }
}
