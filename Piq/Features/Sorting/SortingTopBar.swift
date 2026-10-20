import SwiftUI

/// The sorting screen's top bar: "‹ Albums", the album with its progress in the center, and Undo
/// and Review on the right. Narrow windows trade labels for icons.
struct SortingTopBar: View {
    /// The bar's width (the window's).
    let width: CGFloat
    let title: String
    let state: SortingState
    let canUndo: Bool
    /// Whether ⌘Z is live (only while sorting is the top screen).
    let acceptsShortcuts: Bool
    let onBack: () -> Void
    let onUndo: () -> Void
    let onReview: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The window controls' width (iPadOS 26 windows), which `TopBar` keeps the back button clear of.
    @State private var windowControlsWidth: CGFloat = 0

    var body: some View {
        let fit = SortingBarFit(width: width, textScale: textScale, leadingInset: Metrics.topBarLeadingInset(clearing: windowControlsWidth))
        TopBar {
            backButton(showsTitle: fit.showsBackTitle)
        } center: {
            SortingProgressTitle(title: title, position: state.position, total: state.total, progress: state.progress, barWidth: fit.progressWidth)
        } trailing: {
            HStack(spacing: SortingBarFit.trailingSpacing) {
                UndoButton(showsTitle: fit.showsUndoTitle, acceptsShortcut: acceptsShortcuts, action: onUndo)
                    .disabled(!canUndo)
                ReviewButton(markedCount: state.markedCount, showsTitle: fit.showsReviewTitle, action: onReview)
            }
        }
        .onWindowControlsWidthChange { windowControlsWidth = $0 }
    }

    /// How much body text is scaled at the current text size (1 at the default size). Read from
    /// the environment, so it honors the app's Dynamic Type cap.
    private var textScale: CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        // Scaled from 100 because the metrics round to whole points.
        return UIFontMetrics(forTextStyle: .body).scaledValue(for: 100, compatibleWith: traits) / 100
    }

    private func backButton(showsTitle: Bool) -> some View {
        BackButton(title: "Albums", showsTitle: showsTitle, action: onBack)
            .accessibilityIdentifier(A11yID.Sorting.back)
    }
}

/// Which labels fit in the top bar. `TopBar` centers the title, so the title gets twice the room
/// the wider side leaves it; Undo's label goes first, then Review's, and the progress bar shortens
/// before a label has to go. Widths are measured from the bundled fonts at the default text size
/// and scale with Dynamic Type.
private struct SortingBarFit {
    static let trailingSpacing: CGFloat = 8

    let showsBackTitle: Bool
    let showsUndoTitle: Bool
    let showsReviewTitle: Bool
    /// The progress bar: 260pt as designed, shorter in narrow windows.
    let progressWidth: CGFloat

    /// - Parameter leadingInset: Space the back button keeps clear of window controls.
    init(width: CGFloat, textScale s: CGFloat, leadingInset: CGFloat) {
        let icon = Metrics.minTouch
        let backTitled = 37 + 54 * s
        let undoTitled = 45 + 38 * s
        // Trash icon, "Review" and a three-digit badge in the pill.
        let reviewTitled = 63 + 51 * s + max(22, 14 + 22 * s)
        let chrome = 2 * Metrics.barPadding + 2 * Metrics.topBarSpacing
        // The centered title's room between a back button `back` wide and a right side
        // `trailing` wide.
        func room(back: CGFloat, trailing: CGFloat) -> CGFloat {
            width - chrome - 2 * max(leadingInset + back, trailing)
        }

        // (Undo labeled, Review labeled, room the center needs to keep them)
        let options: [(undo: Bool, review: Bool, center: CGFloat)] = [(true, true, 200), (false, true, 160), (false, false, 0)]
        var choice = options[options.count - 1]
        var trailing = 2 * icon + Self.trailingSpacing
        for option in options {
            let buttons = (option.undo ? undoTitled : icon) + Self.trailingSpacing + (option.review ? reviewTitled : icon)
            if room(back: icon, trailing: buttons) >= option.center {
                choice = option
                trailing = buttons
                break
            }
        }
        // "‹ Albums" keeps its label when that costs the title nothing, or when there's room.
        showsBackTitle = room(back: backTitled, trailing: trailing) >= min(120, room(back: icon, trailing: trailing))
        showsUndoTitle = choice.undo
        showsReviewTitle = choice.review
        let center = max(room(back: showsBackTitle ? backTitled : icon, trailing: trailing), 0)
        progressWidth = max(min(Metrics.progressWidth, center, max(90, width * 0.32)), 60)
    }
}

/// The album name, "38 of 400" and a thin progress bar, stacked in the middle of the bar.
private struct SortingProgressTitle: View {
    let title: String
    let position: Int
    let total: Int
    let progress: Double
    let barWidth: CGFloat

    var body: some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.barTitle)
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .accessibilityAddTraits(.isHeader)
            Text("\(position.formatted()) of \(total.formatted())")
                .font(.meta)
                .monospacedDigit()
                .foregroundStyle(Palette.textMuted)
                .lineLimit(1)
                .accessibilityLabel("Photo \(position.formatted()) of \(total.formatted())")
                .accessibilityValue("\(progress.formatted(.percent.precision(.fractionLength(0)))) sorted")
                .accessibilityIdentifier(A11yID.Sorting.counter)
            // Read with the counter: a 3pt bar is too small to find by touch.
            ThinProgressBar(progress: progress, width: barWidth)
                .accessibilityHidden(true)
                .padding(.top, 6)
        }
    }
}

/// "↶ Undo", dimmed when there is nothing to take back. ⌘Z does the same.
private struct UndoButton: View {
    let showsTitle: Bool
    let acceptsShortcut: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 16, weight: .semibold))
                if showsTitle {
                    Text("Undo")
                }
            }
        }
        .buttonStyle(.bar)
        .keyboardShortcut(acceptsShortcut ? KeyboardShortcut("z", modifiers: .command) : nil)
        .accessibilityLabel("Undo")
        .accessibilityIdentifier(A11yID.Sorting.undo)
    }
}

/// The "Review" pill with the trash icon and the marked count. Without room for the label it is
/// a round icon button with the count on its corner. Either way VoiceOver finds one element,
/// "Review, 4 marked".
private struct ReviewButton: View {
    let markedCount: Int
    let showsTitle: Bool
    let action: () -> Void

    var body: some View {
        Group {
            if showsTitle {
                Button(action: action) {
                    HStack(spacing: 8) {
                        icon
                        Text("Review")
                        if markedCount > 0 {
                            CountBadge(count: markedCount)
                                // Tucks the round badge into the end of the pill.
                                .padding(.trailing, -8)
                                .transition(.scale(scale: 0.5).combined(with: .opacity))
                        }
                    }
                }
                .buttonStyle(.pill(.secondary))
                .accessibilityLabel(accessibilityLabel)
                .accessibilityIdentifier(A11yID.Sorting.review)
            } else {
                Button(action: action) { icon }
                    .buttonStyle(RoundIconButtonStyle())
                    .accessibilityLabel(accessibilityLabel)
                    .accessibilityIdentifier(A11yID.Sorting.review)
                    .overlay(alignment: .topTrailing) {
                        if markedCount > 0 {
                            // The button's label says the count.
                            CountBadge(count: markedCount)
                                .alignmentGuide(.top) { $0.height / 2 - 2 }
                                .alignmentGuide(.trailing) { $0.width / 2 + 6 }
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                                .transition(.scale(scale: 0.5).combined(with: .opacity))
                        }
                    }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.72), value: markedCount > 0)
    }

    private var accessibilityLabel: String {
        markedCount > 0 ? "Review, \(markedCount.formatted()) marked" : "Review"
    }

    private var icon: some View {
        Image(systemName: "trash")
            .font(.system(size: 15, weight: .medium))
    }
}

/// A 44pt round button that looks like the secondary pill, for an icon on its own.
private struct RoundIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Palette.text)
            .frame(width: Metrics.minTouch, height: Metrics.minTouch)
            .background(Circle().fill(Palette.raised))
            .overlay(Circle().strokeBorder(Palette.hairlineStrong, lineWidth: 1))
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
