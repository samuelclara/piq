import SwiftUI

/// Shown instead of the stage once there is no photo on screen, so the screen never shows an
/// empty stage: a calm summary and the way on to Review, while Review slides in. That is once every
/// photo is sorted, or once Next or a decision moved past the last photo with some skipped (then it
/// offers to go back to the first of them too). If the album's photos were all deleted outside
/// Piq, it says so and offers the way back to the albums instead.
struct SortingCompleteView: View {
    let total: Int
    let sortedCount: Int
    let markedCount: Int
    let onReview: () -> Void
    let onAlbums: () -> Void
    /// Back to the first unsorted photo.
    let onContinue: () -> Void

    private var unsortedCount: Int { max(total - sortedCount, 0) }

    var body: some View {
        VStack(spacing: 0) {
            MessageIcon(systemImage: total == 0 ? "photo" : unsortedCount > 0 ? "flag.checkered" : "checkmark")
                .padding(.bottom, 24)
            Text(title)
                .font(.dialogTitle)
                .foregroundStyle(Palette.text)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 10)
            Text(summary)
                .font(.lead)
                .foregroundStyle(Palette.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
                .padding(.bottom, 28)
            // Side by side, or stacked in a narrow window.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { buttons }
                VStack(spacing: 12) { buttons }
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var buttons: some View {
        if total > 0, unsortedCount > 0 {
            Button(action: onContinue) {
                Text("Continue sorting")
                    .fixedSize()
            }
            .buttonStyle(.pill(.secondary, height: Metrics.largeButtonHeight, font: .largeButtonLabel))
        }
        Button(action: total == 0 ? onAlbums : onReview) {
            Text(total == 0 ? "Albums" : "Review")
                .fixedSize()
                .frame(minWidth: 132)
        }
        .buttonStyle(.pill(.primary, height: Metrics.largeButtonHeight, font: .largeButtonLabel))
    }

    private var title: String {
        if total > 0, unsortedCount > 0 {
            return "That was the last photo"
        }
        switch total {
        case 0: return "No photos left to sort"
        case 1: return "The photo is sorted"
        default: return "All \(Copy.photos(total)) sorted"
        }
    }

    private var summary: String {
        if total == 0 {
            return "The photos in this album were deleted or moved in Photos."
        }
        if unsortedCount > 0 {
            let verb = unsortedCount == 1 ? "is" : "are"
            return "\(sortedCount.formatted()) of \(total.formatted()) sorted so far. \(Copy.photos(unsortedCount)) you skipped \(verb) still unsorted."
        }
        if markedCount == 0 {
            return "Nothing is marked for deletion."
        }
        return "\(Copy.photos(markedCount)) marked for deletion. Nothing leaves Photos until you empty the trash."
    }
}
