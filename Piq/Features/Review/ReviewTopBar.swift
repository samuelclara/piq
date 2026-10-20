import SwiftUI

/// The review screen's top bar: "‹ Continue sorting" (or "‹ Albums") and the album name. The name
/// is centered when it fits there in full; otherwise (a long name, a narrow window, large text)
/// it moves toward the back button, and the back button then drops its label (VoiceOver still
/// reads it), as on the sorting screen, before the name truncates at the end (see `TopBar`).
struct ReviewTopBar: View {
    let albumTitle: String
    let backTitle: String
    let goBack: () -> Void

    var body: some View {
        TopBar(leadingGivesWay: true) {
            ViewThatFits(in: .horizontal) {
                backButton(showsTitle: true)
                backButton(showsTitle: false)
            }
        } center: {
            Text(albumTitle)
                .font(.barTitle)
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
        } trailing: {
            EmptyView()
        }
    }

    private func backButton(showsTitle: Bool) -> some View {
        BackButton(title: backTitle, showsTitle: showsTitle, action: goBack)
            .accessibilityIdentifier(A11yID.Review.back)
    }
}
