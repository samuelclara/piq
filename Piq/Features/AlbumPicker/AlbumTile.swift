import SwiftUI

/// One album in the picker grid: its cover, name and photo count. The whole tile is a single
/// button that selects the album.
struct AlbumTile: View {
    /// Space between the cover and the album name.
    static let titleSpacing: CGFloat = 12
    /// Space between the album name and the photo count.
    static let countSpacing: CGFloat = 3

    let album: AlbumSummary
    let isSelected: Bool
    let coverSize: CGSize
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 0) {
                AlbumCover(assetID: album.coverAssetID, size: coverSize, isSelected: isSelected)
                Text(album.title)
                    .font(.tileTitle)
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .padding(.top, Self.titleSpacing)
                Text(Copy.photos(album.photoCount))
                    .font(.meta)
                    .foregroundStyle(Palette.textMuted)
                    .lineLimit(1)
                    .padding(.top, Self.countSpacing)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(AlbumTileButtonStyle())
        .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: Metrics.tileCorner, style: .continuous))
        .hoverEffect(.highlight)
        .accessibilityLabel("\(album.title), \(Copy.photos(album.photoCount))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(A11yID.Picker.album(album.title))
    }
}

/// The album's newest photo with rounded corners; when selected, an off-white ring just outside
/// it and a check in its top-right corner.
private struct AlbumCover: View {
    let assetID: String?
    let size: CGSize
    let isSelected: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        AssetThumbnail(assetID: assetID, pointSize: size)
            .frame(maxWidth: .infinity)
            .frame(height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.tileCorner, style: .continuous))
            .overlay {
                if isSelected {
                    SelectionRing()
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 1.03)))
                }
            }
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    SelectionCircle(isSelected: true)
                        .padding(10)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.6)))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.82), value: isSelected)
    }
}

/// A 3pt off-white ring drawn 3pt outside the cover, its corners concentric with the cover's.
private struct SelectionRing: View {
    static let gap: CGFloat = 3
    static let lineWidth: CGFloat = 3

    var body: some View {
        let outset = Self.gap + Self.lineWidth
        RoundedRectangle(cornerRadius: Metrics.tileCorner + outset, style: .continuous)
            .strokeBorder(Palette.text, lineWidth: Self.lineWidth)
            .padding(-outset)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Dims and slightly shrinks the tile while it is pressed.
private struct AlbumTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Stand-in for a tile while the albums load: raised shapes with the tile's geometry.
struct AlbumTilePlaceholder: View {
    let coverSize: CGSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RoundedRectangle(cornerRadius: Metrics.tileCorner, style: .continuous)
                .fill(Palette.raised)
                .frame(height: coverSize.height)
            PlaceholderLine(font: .tileTitle, width: coverSize.width * 0.5, height: 12)
                .padding(.top, AlbumTile.titleSpacing)
            PlaceholderLine(font: .meta, width: coverSize.width * 0.28, height: 10)
                .padding(.top, AlbumTile.countSpacing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A rounded bar as tall as a line of `font`, so a placeholder tile matches a loaded one.
private struct PlaceholderLine: View {
    let font: Font
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        Text(verbatim: "Album")
            .font(font)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Palette.raised)
                    .frame(width: width, height: height)
            }
    }
}
