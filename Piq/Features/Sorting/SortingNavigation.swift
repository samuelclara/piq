import SwiftUI

extension PhotoStep {
    /// The button's VoiceOver label and the photo's accessibility action.
    var title: String {
        switch self {
        case .previous: "Previous photo"
        case .next: "Next photo"
        }
    }

    var systemImage: String {
        switch self {
        case .previous: "chevron.left"
        case .next: "chevron.right"
        }
    }

    /// ⌘[ and ⌘], Back and Forward across Apple's apps. The arrow keys stay with the decisions
    /// (← and →), and ↑ and ↓ stay with the keyboard focus, which Full Keyboard Access moves with
    /// them.
    var keyboardShortcut: KeyboardShortcut {
        switch self {
        case .previous: KeyboardShortcut("[", modifiers: .command)
        case .next: KeyboardShortcut("]", modifiers: .command)
        }
    }

    var accessibilityID: String {
        switch self {
        case .previous: A11yID.Sorting.previous
        case .next: A11yID.Sorting.next
        }
    }
}

extension A11yID.Sorting {
    static let previous = "sorting.previous"
    static let next = "sorting.next"
    static let decisionTag = "sorting.decisionTag"
}

extension Verdict {
    /// "Marked for deletion" while the photo is in the trash, otherwise "Kept" (a photo restored
    /// in Review counts as kept, as in Review's numbers).
    var tagTitle: String {
        isMarked ? "Marked for deletion" : "Kept"
    }

    var tagTint: Tint {
        isMarked ? .coral : .sky
    }

    var tagSystemImage: String {
        isMarked ? SwipeAction.delete.systemImage : SwipeAction.keep.systemImage
    }
}

/// A decided photo's decision, on the card when the person comes back to it: a chip like the
/// filename's, tinted coral ("Marked for deletion") or sky ("Kept"), or its icon alone on a photo
/// too narrow for the words beside the filename. VoiceOver reads it in the photo's label.
struct DecisionTag: View {
    let verdict: Verdict
    /// The icon alone (trash or checkmark), in the same tinted capsule.
    var isCompact = false

    var body: some View {
        let tint = verdict.tagTint
        HStack(spacing: isCompact ? 0 : 5) {
            Image(systemName: verdict.tagSystemImage)
                .font(.system(size: 11, weight: .bold))
            // Compact, the words still set the height (at no width), so the tag stays as tall as
            // the filename chip beside it.
            Text(verdict.tagTitle)
                .font(.chip)
                .lineLimit(1)
                .frame(width: isCompact ? 0 : nil)
                .opacity(isCompact ? 0 : 1)
        }
        .foregroundStyle(tint.label)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            ZStack {
                Capsule().fill(Color.black.opacity(0.55))
                Capsule().fill(tint.fill)
            }
        }
        .overlay(Capsule().strokeBorder(tint.border, lineWidth: 1))
        .fixedSize()
        .accessibilityHidden(true)
        .accessibilityIdentifier(A11yID.Sorting.decisionTag)
    }
}

/// Previous or Next: a 44pt round stroke chevron, dimmed when there is nowhere to go. It reads as
/// moving through the photos, not as a decision: no tint, and it sits with the "38 of 400" it
/// changes, away from Delete and Keep. In a narrow window it moves to a row of its own under the
/// photo and says "Previous" or "Next" beside the chevron (see `PhotoStepRow`).
struct PhotoStepButton: View {
    let step: PhotoStep
    var showsTitle = false
    /// Whether ⌘[ / ⌘] is live (only while sorting is the top screen).
    let acceptsShortcut: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if showsTitle, step == .next {
                    Text(step.shortTitle)
                }
                // A title for the keyboard shortcuts list (hold ⌘), which shows the button's text.
                Label(step.title, systemImage: step.systemImage)
                    .labelStyle(.iconOnly)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: Metrics.minTouch, height: Metrics.minTouch)
                    .overlay(Circle().strokeBorder(Palette.hairlineStrong, lineWidth: 1))
                if showsTitle, step == .previous {
                    Text(step.shortTitle)
                }
            }
        }
        .buttonStyle(PhotoStepButtonStyle())
        .buttonRepeatBehavior(.disabled)
        .keyboardShortcut(acceptsShortcut ? step.keyboardShortcut : nil)
        .accessibilityLabel(step.title)
        .accessibilityIdentifier(step.accessibilityID)
    }
}

/// Previous and Next in a row of their own, at the two sides under the photo, where the top bar
/// is too narrow to hold them by the counter (see `SortingBarFit.holdsStepButtons`). Under the
/// photo rather than over it: the toasts ("Marked for deletion") come down under the top bar and
/// would hide it. Untinted and labeled "Previous" and "Next", so it doesn't read as the Delete
/// and Keep pills below it.
struct PhotoStepRow: View {
    let canGoBack: Bool
    let canGoForward: Bool
    let acceptsShortcuts: Bool
    let onStep: (PhotoStep) -> Void

    var body: some View {
        HStack(spacing: 12) {
            PhotoStepButton(step: .previous, showsTitle: true, acceptsShortcut: acceptsShortcuts) { onStep(.previous) }
                .disabled(!canGoBack)
            Spacer(minLength: 0)
            PhotoStepButton(step: .next, showsTitle: true, acceptsShortcut: acceptsShortcuts) { onStep(.next) }
                .disabled(!canGoForward)
        }
    }
}

extension PhotoStep {
    /// "Previous" or "Next", beside the chevron in a narrow window.
    var shortTitle: String {
        switch self {
        case .previous: "Previous"
        case .next: "Next"
        }
    }
}

/// Dims a little while pressed, and to a third when disabled.
private struct PhotoStepButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.buttonLabel)
            .lineLimit(1)
            .foregroundStyle(Palette.text)
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.35)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.2), value: isEnabled)
    }
}
