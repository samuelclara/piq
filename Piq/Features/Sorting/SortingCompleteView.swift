import SwiftUI

/// Shown instead of the stage once every photo is sorted, so the screen never shows an empty
/// stage: a calm summary and the way on to Review. (If the album's photos were all deleted
/// outside Piq, it says so and offers the way back to the albums instead.)
struct SortingCompleteView: View {
    let total: Int
    let markedCount: Int
    let onReview: () -> Void
    let onAlbums: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            MessageIcon(systemImage: total == 0 ? "photo" : "checkmark")
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
            Button(action: total == 0 ? onAlbums : onReview) {
                Text(total == 0 ? "Albums" : "Review")
                    .frame(minWidth: 132)
            }
            .buttonStyle(.pill(.primary, height: Metrics.largeButtonHeight, font: .largeButtonLabel))
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        switch total {
        case 0: "No photos left to sort"
        case 1: "The photo is sorted"
        default: "All \(Copy.photos(total)) sorted"
        }
    }

    private var summary: String {
        if total == 0 {
            return "The photos in this album were deleted or moved in Photos."
        }
        if markedCount == 0 {
            return "Nothing is marked for deletion."
        }
        return "\(Copy.photos(markedCount)) marked for deletion. Nothing leaves Photos until you empty the trash."
    }
}
