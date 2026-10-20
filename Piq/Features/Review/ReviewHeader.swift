import SwiftUI

/// "Review", the summary line, and the sorted / kept / to delete counts. The counts sit to the
/// right of the title, with the summary wrapping beside them if it must (portrait); they move
/// under the title only in narrow windows, where the title would get narrower than
/// `minimumTitleWidth`.
struct ReviewHeader: View {
    let state: SortingState

    /// Narrowest the title and summary get beside the counts: the summary takes two lines there.
    private static let minimumTitleWidth: CGFloat = 320

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .lastTextBaseline, spacing: 40) {
                titleBlock
                    .frame(minWidth: Self.minimumTitleWidth, idealWidth: Self.minimumTitleWidth, maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                stats
                    .fixedSize()
            }
            VStack(alignment: .leading, spacing: 24) {
                titleBlock
                stats
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ReviewCopy.title)
                .font(.screenTitle)
                .foregroundStyle(Palette.text)
                .accessibilityAddTraits(.isHeader)
            Text(ReviewCopy.summary(sorted: state.sortedCount, total: state.total))
                .font(.lead)
                .foregroundStyle(Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(A11yID.Review.summary)
        }
    }

    private var stats: some View {
        HStack(alignment: .top, spacing: 36) {
            ReviewStat(value: state.sortedCount, label: "sorted", color: Palette.text)
            ReviewStat(value: state.keptCount, label: "kept", color: Palette.sky)
            ReviewStat(value: state.markedCount, label: "to delete", color: Palette.coral)
        }
    }
}

/// A large display number over a small muted label.
private struct ReviewStat: View {
    let value: Int
    let label: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value.formatted())
                .font(.statNumber)
                .monospacedDigit()
                .foregroundStyle(color)
                .contentTransition(.numericText(value: Double(value)))
            Text(label)
                .font(.statLabel)
                .foregroundStyle(Palette.textMuted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value.formatted()) \(label)")
    }
}
