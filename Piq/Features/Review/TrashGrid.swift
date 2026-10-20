import SwiftUI

/// The photos in the trash: square tiles, 12pt apart, scrolling under the fixed header.
struct TrashGrid: View {
    let trash: [String]
    /// Width of the screen; the grid sits between the page margins.
    let containerWidth: CGFloat
    let margin: CGFloat
    let model: ReviewModel
    /// Where the full-screen preview zooms out of its tile.
    let previewZoom: Namespace.ID
    /// Called when the grid scrolls away from the top, or back to it.
    var onScrolledChange: (Bool) -> Void = { _ in }

    var body: some View {
        let width = containerWidth - 2 * margin
        let columnCount = Self.columnCount(gridWidth: width, windowWidth: containerWidth)
        let gaps = Metrics.thumbGap * CGFloat(columnCount - 1)
        let side = max(1, ((width - gaps) / CGFloat(columnCount)).rounded(.up))
        ScrollView {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: Metrics.thumbGap), count: columnCount),
                spacing: Metrics.thumbGap
            ) {
                ForEach(trash, id: \.self) { assetID in
                    TrashTile(
                        assetID: assetID,
                        metadata: model.metadata[assetID],
                        isSelected: model.isSelected(assetID),
                        side: side,
                        previewZoom: previewZoom,
                        toggle: { model.toggle(assetID) },
                        preview: { model.showPreview(of: assetID) }
                    )
                }
            }
            .padding(.horizontal, margin)
            .padding(.bottom, 28)
        }
        .reportsScrolledFromTop(onScrolledChange)
    }

    /// `Metrics.reviewColumns(forWidth:)` of the grid's own width (6 at full landscape width, 4 in
    /// portrait), but never fewer than 4 once the window is as wide as Split View's narrow panes
    /// (480pt), as SPEC.md asks. Only very narrow windows get 3.
    static func columnCount(gridWidth: CGFloat, windowWidth: CGFloat) -> Int {
        max(Metrics.reviewColumns(forWidth: gridWidth), min(4, Metrics.reviewColumns(forWidth: windowWidth)))
    }
}

/// One photo in the trash. Dimmed until selected; selected tiles get full brightness, an
/// off-white ring and a checked circle. Tap toggles the selection; a long press opens the
/// full-screen preview.
struct TrashTile: View {
    let assetID: String
    /// The photo's details, once loaded: the filename for the chip and VoiceOver.
    let metadata: PhotoMetadata?
    let isSelected: Bool
    /// Edge length in points, for sizing the thumbnail request.
    let side: CGFloat
    let previewZoom: Namespace.ID
    let toggle: () -> Void
    let preview: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPressed = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Metrics.thumbCorner, style: .continuous)
    }

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                // Loads again on its own, keeping the smaller image meanwhile, when the tile grows
                // well past the size it was loaded at (a narrow window made full screen).
                AssetThumbnail(assetID: assetID, pointSize: CGSize(width: side, height: side))
            }
            .overlay {
                Color.black.opacity(isSelected ? 0 : 0.28)
            }
            .clipShape(shape)
            .overlay {
                if isSelected {
                    shape.strokeBorder(Palette.text, lineWidth: 3)
                }
            }
            .overlay(alignment: .topTrailing) {
                SelectionCircle(isSelected: isSelected)
                    .padding(8)
            }
            .overlay(alignment: .bottomLeading) {
                if let filename = metadata?.filename {
                    // Small tiles drop the extension rather than truncate the number.
                    ViewThatFits(in: .horizontal) {
                        PhotoChip(text: filename)
                        PhotoChip(text: (filename as NSString).deletingPathExtension)
                    }
                    .padding(8)
                }
            }
            .reviewZoomSource(id: assetID, in: previewZoom)
            .contentShape(.interaction, shape)
            .contentShape(.hoverEffect, shape)
            .hoverEffect(.lift)
            .scaleEffect(isPressed && !reduceMotion ? 0.97 : 1)
            .animation(.easeOut(duration: 0.16), value: isSelected)
            .animation(.easeOut(duration: 0.2), value: isPressed)
            // The long press goes first. Attached after the tap, it only won once a press passed
            // about 0.75s, so a normal long press selected the photo instead.
            .onLongPressGesture(minimumDuration: 0.4, perform: preview) { pressing in
                isPressed = pressing
            }
            .onTapGesture(perform: toggle)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ReviewCopy.photoLabel(metadata))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityHint(isSelected ? "Deselects the photo" : "Selects the photo")
            .accessibilityAction(.default, toggle)
            .accessibilityAction(named: "Preview", preview)
            .accessibilityIdentifier(A11yID.Review.tile(assetID))
    }
}

private extension View {
    /// Calls `action` with whether a scroll view has moved away from its top (iOS 18 and later;
    /// earlier systems never report it).
    @ViewBuilder
    func reportsScrolledFromTop(_ action: @escaping (Bool) -> Void) -> some View {
        if #available(iOS 18.0, *) {
            onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > 1
            } action: { _, isScrolled in
                action(isScrolled)
            }
        } else {
            self
        }
    }
}
