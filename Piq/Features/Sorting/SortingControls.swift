import SwiftUI

/// The pills under the photo, one per `SwipeAction` ("← Delete", "Keep →"), each with its arrow
/// key, and the swipe hint under them.
struct SortingControls: View {
    let buttonWidth: CGFloat
    /// Whether the arrow keys are live (only while sorting is the top screen).
    let acceptsShortcuts: Bool
    let onDecide: (SwipeAction) -> Void

    /// Left-swipe actions first, so each button sits on the side its swipe goes to.
    private static let actions = SwipeAction.allCases.filter { $0.direction == .left } + SwipeAction.allCases.filter { $0.direction == .right }

    /// The label's share of a pill `buttonWidth` wide.
    private var labelWidth: CGFloat {
        max(0, buttonWidth - 2 * PillButtonStyle.horizontalPadding(forHeight: Metrics.actionButtonHeight))
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: SortingLayout.actionSpacing) {
                ForEach(Self.actions, id: \.self) { action in
                    Button {
                        onDecide(action)
                    } label: {
                        Text(action.buttonTitle)
                            .frame(minWidth: labelWidth)
                    }
                    .buttonStyle(.pill(.tinted(action.tint), height: Metrics.actionButtonHeight, font: .largeButtonLabel))
                    .keyboardShortcut(acceptsShortcuts ? KeyboardShortcut(action.keyEquivalent, modifiers: []) : nil)
                    .accessibilityLabel(action.title)
                    .accessibilityIdentifier(action.sortingButtonID)
                }
            }
            // A held arrow key (or a long press) decides one photo, as on the photo itself.
            .buttonRepeatBehavior(.disabled)
            Text(Self.hint)
                .font(.hint)
                .foregroundStyle(Palette.textMuted)
                .accessibilityLabel(Self.hint.spoken)
        }
    }

    private static let hint = "Swipe left to delete · right to keep"
}

extension SwipeAction {
    /// Identifier of the action's pill on the sorting screen.
    var sortingButtonID: String {
        switch self {
        case .delete: A11yID.Sorting.delete
        case .keep: A11yID.Sorting.keep
        }
    }
}
