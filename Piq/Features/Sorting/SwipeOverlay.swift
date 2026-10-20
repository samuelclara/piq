import SwiftUI

/// The tint that fades in over a card as it is dragged: the action for that side's color, its
/// icon and its name. It reaches full strength at the swipe threshold.
struct SwipeOverlay: View {
    /// Horizontal distance from the card's resting place.
    let translation: CGFloat

    var body: some View {
        if translation != 0 {
            let action = SwipeAction.action(for: translation < 0 ? .left : .right)
            let strength = min(abs(translation) / Metrics.swipeThreshold, 1)
            ZStack {
                action.overlayColor
                    .opacity(strength * Metrics.maxOverlayOpacity)
                VStack(spacing: 12) {
                    Image(systemName: action.systemImage)
                        .font(.system(size: 64, weight: .medium))
                    Text(action.title)
                        .font(.overlayLabel)
                }
                .foregroundStyle(Palette.ink)
                .opacity(strength)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
