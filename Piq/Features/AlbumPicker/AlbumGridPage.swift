import SwiftUI

/// The picker's scrolling page when Piq can read Photos: the intro, the limited-access notice
/// if needed, then the album grid (placeholder tiles until the albums load).
struct AlbumGridPage: View {
    let layout: PickerLayout
    /// Set while content is scrolled under the header.
    @Binding var isScrolled: Bool

    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PickerIntro()
                if app.access == .limited {
                    LimitedAccessNotice(isStacked: layout.isNarrow)
                        .padding(.top, 20)
                }
                albums
                    .padding(.top, PickerLayout.gridTopPadding)
            }
            .padding(.horizontal, layout.margin)
            .padding(.top, PickerLayout.introTopPadding)
            .padding(.bottom, PickerLayout.gridBottomPadding)
            .onGeometryChange(for: Bool.self) { proxy in
                proxy.frame(in: .named(ScrollSpace.name)).minY < -1
            } action: { scrolled in
                isScrolled = scrolled
            }
        }
        .coordinateSpace(.named(ScrollSpace.name))
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityIdentifier(A11yID.Picker.grid)
    }

    @ViewBuilder
    private var albums: some View {
        if !app.hasLoadedAlbums {
            AlbumGridPlaceholder(layout: layout)
        } else if app.albums.isEmpty {
            NoAlbumsMessage()
        } else {
            AlbumGrid(layout: layout)
        }
    }
}

private enum ScrollSpace {
    static let name = "albumPicker.scroll"
}

/// The album tiles. Tapping one selects it, except while an album opens: the selection then stays
/// on the album being opened.
private struct AlbumGrid: View {
    let layout: PickerLayout

    @Environment(AppModel.self) private var app

    var body: some View {
        LazyVGrid(columns: layout.gridItems, alignment: .leading, spacing: layout.rowSpacing) {
            ForEach(app.albums) { album in
                AlbumTile(album: album, isSelected: album.id == app.selectedAlbumID, coverSize: layout.coverSize) {
                    app.selectedAlbumID = album.id
                }
            }
        }
        .disabled(app.isOpeningAlbum)
    }
}

/// Two rows of placeholder tiles, gently pulsing while the albums load.
private struct AlbumGridPlaceholder: View {
    let layout: PickerLayout

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDimmed = false

    var body: some View {
        LazyVGrid(columns: layout.gridItems, alignment: .leading, spacing: layout.rowSpacing) {
            ForEach(0..<(layout.columns * 2), id: \.self) { _ in
                AlbumTilePlaceholder(coverSize: layout.coverSize)
            }
        }
        .opacity(isDimmed ? 0.5 : 1)
        .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: isDimmed)
        .onAppear { isDimmed = !reduceMotion }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading albums")
    }
}

/// Shown if Photos lists no albums at all.
private struct NoAlbumsMessage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No albums yet")
                .font(.tileTitle)
                .foregroundStyle(Palette.text)
            Text("Albums you make in Photos show up here.")
                .font(.lead)
                .foregroundStyle(Palette.textMuted)
        }
        .accessibilityElement(children: .combine)
    }
}
