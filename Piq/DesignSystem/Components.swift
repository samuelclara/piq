import SwiftUI

/// The "piq" wordmark: lowercase, followed by a small sky-blue dot.
struct Wordmark: View {
    var size: CGFloat = 30

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: size * 0.06) {
            Text("piq")
                .font(.display(size, .bold))
                .foregroundStyle(Palette.text)
            Circle()
                .fill(Palette.sky)
                .frame(width: size * 0.22, height: size * 0.22)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Piq")
        .accessibilityAddTraits(.isHeader)
    }
}

/// The 76pt bar at the top of the sorting and review screens: leading, centered and trailing
/// content over a hairline. The sides keep their full width; the center is centered in the bar
/// when it fits between them, and otherwise moves aside just enough to fit, truncating only when
/// the space between the sides is too narrow for it. In an iPadOS 26 window, the leading content
/// starts after the window controls.
///
/// With `leadingGivesWay`, the leading side is offered only the room the center leaves it, so a
/// `ViewThatFits` there (a back button with and without its label) gives way before the center
/// truncates.
struct TopBar<Leading: View, Center: View, Trailing: View>: View {
    private let leadingGivesWay: Bool
    private let leading: Leading
    private let center: Center
    private let trailing: Trailing
    @State private var windowControlsWidth: CGFloat = 0

    init(
        leadingGivesWay: Bool = false,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder center: () -> Center,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.leadingGivesWay = leadingGivesWay
        self.leading = leading()
        self.center = center()
        self.trailing = trailing()
    }

    var body: some View {
        TopBarLayout(
            spacing: Metrics.topBarSpacing,
            leadingInset: Metrics.topBarLeadingInset(clearing: windowControlsWidth),
            leadingGivesWay: leadingGivesWay
        ) {
            // Each part is one subview, even when it's empty.
            HStack(spacing: 0) { leading }
            HStack(spacing: 0) { center }
            HStack(spacing: 0) { trailing }
        }
        .padding(.horizontal, Metrics.barPadding)
        .frame(height: Metrics.topBarHeight)
        .frame(maxWidth: .infinity)
        .background(Palette.ground)
        .overlay(alignment: .bottom) { Hairline() }
        .onWindowControlsWidthChange { windowControlsWidth = $0 }
        // A group of its own: otherwise VoiceOver lands on the hairline, hidden as it is, as an
        // empty element after the bar.
        .accessibilityElement(children: .contain)
    }
}

/// Places a top bar's leading, center and trailing subviews (see `TopBar`).
struct TopBarLayout: Layout {
    var spacing: CGFloat
    var leadingInset: CGFloat
    /// Whether the leading side is offered only the room the center leaves it (see `TopBar`).
    var leadingGivesWay = false

    /// The width offered to a leading side `idealWidth` wide in a bar `barWidth` wide: all it
    /// wants, or, when it gives way, no more than the center leaves it (never below zero).
    static func leadingOffer(
        idealWidth: CGFloat,
        barWidth: CGFloat,
        trailingWidth: CGFloat,
        centerWidth: CGFloat,
        spacing: CGFloat,
        leadingInset: CGFloat,
        givesWay: Bool
    ) -> CGFloat {
        guard givesWay else { return idealWidth }
        let room = barWidth - leadingInset - 2 * spacing - trailingWidth - centerWidth
        return min(idealWidth, max(room, 0))
    }

    /// The center's horizontal span in a bar spanning `bounds` (x and width): centered when it
    /// fits between the sides, nudged toward the roomier side when it doesn't, and narrowed to
    /// the space between the sides when even that is too little.
    static func centerSpan(
        in bounds: ClosedRange<CGFloat>,
        leadingWidth: CGFloat,
        trailingWidth: CGFloat,
        centerWidth: CGFloat,
        spacing: CGFloat,
        leadingInset: CGFloat
    ) -> (x: CGFloat, width: CGFloat) {
        let start = bounds.lowerBound + leadingInset + leadingWidth + spacing
        let end = bounds.upperBound - trailingWidth - spacing
        let width = min(centerWidth, max(end - start, 0))
        let midX = (bounds.lowerBound + bounds.upperBound) / 2
        return (max(start, min(midX - width / 2, end - width)), width)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let idealWidth = leadingInset + sizes.map(\.width).reduce(0, +) + spacing * CGFloat(max(subviews.count - 1, 0))
        return CGSize(width: proposal.width ?? idealWidth, height: proposal.height ?? sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let (leading, center, trailing) = (subviews[0], subviews[1], subviews[2])
        let trailingWidth = trailing.sizeThatFits(.unspecified).width
        let centerWidth = center.sizeThatFits(.unspecified).width
        let leadingOffer = Self.leadingOffer(
            idealWidth: leading.sizeThatFits(.unspecified).width,
            barWidth: bounds.width,
            trailingWidth: trailingWidth,
            centerWidth: centerWidth,
            spacing: spacing,
            leadingInset: leadingInset,
            givesWay: leadingGivesWay
        )
        let leadingProposal = ProposedViewSize(width: leadingOffer, height: bounds.height)
        let leadingWidth = leading.sizeThatFits(leadingProposal).width
        leading.place(at: CGPoint(x: bounds.minX + leadingInset, y: bounds.midY), anchor: .leading, proposal: leadingProposal)
        trailing.place(
            at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing,
            proposal: ProposedViewSize(width: trailingWidth, height: bounds.height)
        )
        let span = Self.centerSpan(
            in: bounds.minX...bounds.maxX,
            leadingWidth: leadingWidth,
            trailingWidth: trailingWidth,
            centerWidth: centerWidth,
            spacing: spacing,
            leadingInset: leadingInset
        )
        center.place(at: CGPoint(x: span.x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: span.width, height: bounds.height))
    }
}

struct Hairline: View {
    var color: Color = Palette.hairline

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(height: Metrics.hairline)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Pads the leading edge by `minimum`, or more where iPadOS 26 shows its window controls in
    /// the window's top-leading corner, so the content starts after them. Padding (unlike an
    /// offset) takes part in layout, so nothing beside the content can end up under it.
    func leadingPaddingClearingWindowControls(_ minimum: CGFloat) -> some View {
        modifier(WindowControlsPadding(minimum: minimum))
    }

    /// Reports how wide the window controls iPadOS 26 shows in the window's top-leading corner
    /// are, measured from this view's leading edge (0 when they don't overlap it, and before
    /// iPadOS 26).
    @ViewBuilder
    func onWindowControlsWidthChange(_ action: @escaping (CGFloat) -> Void) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            onGeometryChange(for: CGFloat.self) { proxy in
                let corner = proxy.containerCornerInsets.topLeading
                return corner.height > 0 ? corner.width : 0
            } action: { width in
                action(width)
            }
        } else {
            self
        }
        #else
        self
        #endif
    }
}

private struct WindowControlsPadding: ViewModifier {
    let minimum: CGFloat
    @State private var windowControlsWidth: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .padding(.leading, max(minimum, windowControlsWidth))
            .onWindowControlsWidthChange { windowControlsWidth = $0 }
    }
}

/// Thin progress bar (260pt by default) under the counter in the sorting top bar.
struct ThinProgressBar: View {
    var progress: Double
    var width: CGFloat = Metrics.progressWidth

    var body: some View {
        let clamped = min(max(progress, 0), 1)
        Capsule()
            .fill(Palette.hairlineStrong)
            .frame(width: width, height: 3)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Palette.text)
                    .frame(width: width * clamped, height: 3)
            }
            .animation(.easeOut(duration: 0.25), value: clamped)
            .accessibilityElement()
            .accessibilityLabel("Progress")
            .accessibilityValue(Text(clamped, format: .percent.precision(.fractionLength(0))))
    }
}

/// Solid coral count badge with dark text.
struct CountBadge: View {
    let count: Int

    var body: some View {
        Text(count.formatted())
            .font(.badge)
            .monospacedDigit()
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 7)
            .frame(minWidth: 22, minHeight: 22)
            .background(Capsule().fill(Palette.coral))
    }
}

/// Selection circle for tiles: hollow when off; filled off-white with a check when on.
struct SelectionCircle: View {
    let isSelected: Bool
    var size: CGFloat = 26

    var body: some View {
        ZStack {
            if isSelected {
                Circle().fill(Palette.text)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.46, weight: .bold))
                    .foregroundStyle(Palette.ink)
            } else {
                Circle().fill(Color.black.opacity(0.28))
                Circle().strokeBorder(Palette.text.opacity(0.9), lineWidth: 2)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
        .accessibilityHidden(true)
    }
}

/// Small dark chip over a photo, e.g. "IMG_4838.HEIC · 14:32".
struct PhotoChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.chip)
            .foregroundStyle(Palette.text)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.black.opacity(0.55)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }
}

/// A stroke icon in a quiet circle, heading a message page: the picker without Photos access,
/// the sorting screen once everything is sorted, Review's empty trash. Each of those pages then
/// has a `dialogTitle`, a `lead` line or two, and one 56pt primary pill.
struct MessageIcon: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 30, weight: .regular))
            .foregroundStyle(Palette.text)
            .frame(width: 80, height: 80)
            .background(Circle().fill(Palette.raised))
            .overlay(Circle().strokeBorder(Palette.hairlineStrong, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// Stand-in while an image loads (or when an album has no photos).
struct PhotoPlaceholder: View {
    var showsIcon = true

    var body: some View {
        Rectangle()
            .fill(Palette.raised)
            .overlay {
                if showsIcon {
                    Image(systemName: "photo")
                        .font(.system(size: 26, weight: .regular))
                        .foregroundStyle(Palette.textMuted.opacity(0.6))
                }
            }
            .accessibilityHidden(true)
    }
}

/// An aspect-fill thumbnail for an asset, loaded through the app's image source at the size it's
/// shown. Give it a frame; it fills and clips to it. When it grows well past the size it was loaded
/// at (a window made larger), it loads again at the new size and keeps the smaller image on screen
/// meanwhile; it doesn't reload for small changes or when it shrinks.
///
/// It lets go of its image when it goes off screen, since a lazy grid keeps every tile it has
/// shown, so a long grid holds only the thumbnails on screen however far it's scrolled. It loads
/// again when it comes back (at once if the image source still has it, as it keeps the last
/// few), and a thumbnail that couldn't be loaded is asked for again then too.
struct AssetThumbnail: View {
    let assetID: String?
    /// The size the thumbnail is shown at, in points.
    let pointSize: CGSize

    @Environment(AppModel.self) private var app
    @Environment(\.displayScale) private var displayScale
    /// The image on screen, held by reference (see `ThumbnailContent`).
    @State private var content = ThumbnailContent()
    /// What the image on screen was loaded for.
    @State private var loaded: Request?

    var body: some View {
        PhotoPlaceholder(showsIcon: assetID == nil)
            .overlay {
                if let image = content.image, loaded?.assetID == assetID {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                }
            }
            .clipped()
            .task(id: request) {
                await load(request)
            }
            .onDisappear {
                content.image = nil
                loaded = nil
            }
    }

    /// A photo at a size, in points at a display scale.
    private struct Request: Equatable {
        /// How much larger than its loaded image a thumbnail can be shown before it loads again.
        static let growthAllowance: CGFloat = 1.2

        let assetID: String
        let pointSize: CGSize
        let scale: CGFloat

        /// Whether an image loaded for this request is sharp enough for `other`.
        func covers(_ other: Request) -> Bool {
            assetID == other.assetID
                && pointSize.width * scale * Self.growthAllowance >= other.pointSize.width * other.scale
                && pointSize.height * scale * Self.growthAllowance >= other.pointSize.height * other.scale
        }
    }

    /// What the thumbnail needs now: what it has loaded, as long as that's sharp enough. Nothing
    /// while it's laid out too small to see (a grid's first pass, before it knows its width).
    private var request: Request? {
        guard let assetID, pointSize.width >= 4, pointSize.height >= 4 else { return nil }
        let wanted = Request(assetID: assetID, pointSize: pointSize, scale: displayScale)
        if let loaded, loaded.covers(wanted) {
            return loaded
        }
        return wanted
    }

    private func load(_ request: Request?) async {
        guard let request, request != loaded else { return }
        let start = ContinuousClock.now
        let thumbnail = await app.images.thumbnail(for: request.assetID, pointSize: request.pointSize, scale: request.scale)
        guard !Task.isCancelled else { return }
        let isSamePhoto = loaded?.assetID == request.assetID && content.image != nil
        guard let thumbnail else {
            // Nothing came (an iCloud thumbnail while offline): keep a smaller copy of the same
            // photo if there is one, and ask again when the tile next appears.
            if !isSamePhoto {
                content.image = nil
                loaded = nil
            }
            return
        }
        // A sharper copy of the same photo, or one that came at once (a tile scrolled back into
        // view), replaces what's on screen without a fade.
        let fades = !isSamePhoto && ContinuousClock.now - start > .milliseconds(30)
        withAnimation(fades ? .easeOut(duration: 0.2) : nil) {
            content.image = thumbnail
            loaded = request
        }
    }
}

/// The image a thumbnail shows, held by reference. SwiftUI keeps what it last built for a tile a
/// lazy grid has scrolled away (its closures among it) and doesn't update it while it's off
/// screen, so anything there holding the image itself would keep the bitmap alive.
@MainActor
@Observable
private final class ThumbnailContent {
    var image: UIImage?
}
