import SwiftUI

/// "Delete 22 photos?": the last check before Piq asks Photos to delete the whole trash.
/// Shown with `.modalCard(isPresented:)`.
struct DeleteConfirmationCard: View {
    /// Photos in the trash: all of them go, whatever is selected.
    let count: Int
    let cancel: () -> Void
    let confirm: () -> Void

    /// VoiceOver starts on the title rather than staying on the dimmed screen behind the card.
    @AccessibilityFocusState private var isTitleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(ReviewCopy.deleteTitle(count))
                .font(.dialogTitle)
                .foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($isTitleFocused)
            Text(ReviewCopy.deleteBody)
                .font(.lead)
                .foregroundStyle(Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            ViewThatFits(in: .horizontal) {
                EqualWidthRow(spacing: 12) {
                    cancelButton
                    deleteButton
                }
                VStack(spacing: 10) {
                    deleteButton
                    cancelButton
                }
            }
            .padding(.top, 28)
        }
        .accessibilityAction(.escape, cancel)
        .onAppear { isTitleFocused = true }
    }

    private var cancelButton: some View {
        Button(action: cancel) {
            Text("Cancel")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.pill(.secondary, height: Metrics.largeButtonHeight, font: .largeButtonLabel))
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier(A11yID.Review.cancelDelete)
    }

    private var deleteButton: some View {
        Button(action: confirm) {
            Text(ReviewCopy.deleteButton(count))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.pill(.destructive, height: Metrics.largeButtonHeight, font: .largeButtonLabel))
        .accessibilityIdentifier(A11yID.Review.confirmDelete)
    }
}

/// Places its subviews side by side at equal widths, filling the width it is offered. Its ideal
/// width is the widest subview's times the count, so inside `ViewThatFits` it gives way to a
/// stacked layout before any label would have to truncate.
private struct EqualWidthRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let count = CGFloat(subviews.count)
        let needed = (sizes.map(\.width).max() ?? 0) * count + spacing * (count - 1)
        return CGSize(width: proposal.width ?? needed, height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let count = CGFloat(subviews.count)
        let width = (bounds.width - spacing * (count - 1)) / count
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX + CGFloat(index) * (width + spacing), y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(width: width, height: bounds.height)
            )
        }
    }
}
