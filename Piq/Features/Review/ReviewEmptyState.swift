import SwiftUI

/// Shown under the header when nothing is marked for deletion, with a way back to sorting (or
/// to the albums once everything is sorted). Scrolls when the window is too short for it.
struct ReviewEmptyState: View {
    let buttonTitle: String
    let goBack: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    .padding(.horizontal, Metrics.pageMargin(forWidth: proxy.size.width))
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11yID.Review.emptyState)
    }

    private var content: some View {
        VStack(spacing: 0) {
            MessageIcon(systemImage: "trash")

            Text(ReviewCopy.emptyTitle)
                .font(.dialogTitle)
                .foregroundStyle(Palette.text)
                .multilineTextAlignment(.center)
                .padding(.top, 24)
                .accessibilityAddTraits(.isHeader)

            Text(ReviewCopy.emptyBody)
                .font(.lead)
                .foregroundStyle(Palette.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
                .padding(.top, 10)

            Button(buttonTitle, action: goBack)
                .buttonStyle(.pill(.primary, height: Metrics.largeButtonHeight, font: .largeButtonLabel))
                .accessibilityIdentifier(A11yID.Review.emptyStateButton)
                .padding(.top, 28)
        }
    }
}
