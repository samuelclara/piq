import SwiftUI

/// The picker's scrolling page when Piq can read Photos: the intro with the search and sort
/// tools, the limited-access notice if needed, then the album grid (placeholder tiles until the
/// albums load), filtered by the search and in the chosen order.
struct AlbumGridPage: View {
    let layout: PickerLayout
    /// Set while content is scrolled under the header.
    @Binding var isScrolled: Bool
    @Binding var searchText: String
    @Binding var sortOrder: AlbumSortOrder
    var isSearchFocused: FocusState<Bool>.Binding

    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                content
            }
            .coordinateSpace(.named(ScrollSpace.name))
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier(A11yID.Picker.grid)
            .background {
                PickerSearchShortcuts(isActive: app.path.isEmpty, searchText: $searchText, isSearchFocused: isSearchFocused) {
                    withAnimation(.easeOut(duration: 0.25)) {
                        scroller.scrollTo(ScrollSpace.top, anchor: .top)
                    }
                }
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            PickerIntro {
                AlbumTools(
                    searchText: $searchText,
                    sortOrder: $sortOrder,
                    isSearchFocused: isSearchFocused,
                    showsSort: AlbumBrowsing.offersSort(app.albums, access: app.access, hasLoaded: app.hasLoadedAlbums)
                )
            }
            .id(ScrollSpace.top)
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

    @ViewBuilder
    private var albums: some View {
        if !app.hasLoadedAlbums {
            AlbumGridPlaceholder(layout: layout)
        } else if app.albums.isEmpty {
            NoAlbumsMessage()
        } else {
            let visible = AlbumBrowsing.visibleAlbums(app.albums, matching: searchText, order: sortOrder)
            if visible.isEmpty {
                NoMatchingAlbums(query: AlbumBrowsing.normalizedQuery(searchText)) {
                    searchText = ""
                }
            } else {
                AlbumGrid(layout: layout, albums: visible)
            }
        }
    }
}

private enum ScrollSpace {
    static let name = "albumPicker.scroll"
    /// The intro at the top of the page, which ⌘F scrolls back to.
    static let top = "albumPicker.top"
}

/// The album tiles. Tapping one selects it, except while an album opens: the selection then stays
/// on the album being opened. A selected album the search hides stays selected.
private struct AlbumGrid: View {
    let layout: PickerLayout
    let albums: [AlbumSummary]

    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LazyVGrid(columns: layout.gridItems, alignment: .leading, spacing: layout.rowSpacing) {
            ForEach(albums) { album in
                AlbumTile(album: album, isSelected: album.id == app.selectedAlbumID, coverSize: layout.coverSize) {
                    app.selectedAlbumID = album.id
                }
            }
        }
        .disabled(app.isOpeningAlbum)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: albums.map(\.id))
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
