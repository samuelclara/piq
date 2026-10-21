import SwiftUI

/// Screen 1: pick the album to sort. Handles every Photos authorization outcome: a quiet wait
/// while the system asks, an explanation with a way to Settings when access is denied or
/// restricted, and the album grid (with a way to change the selection under limited access),
/// which the person can search by name and sort by date created.
struct AlbumPickerScreen: View {
    @Environment(AppModel.self) private var app
    @State private var isScrolled = false
    /// What the album grid is filtered by; kept while Piq runs, not across launches.
    @State private var searchText: String
    @AppStorage(AlbumSortOrder.storageKey) private var sortOrder: AlbumSortOrder = .photos
    @FocusState private var isSearchFocused: Bool

    init(searchText: String = "") {
        _searchText = State(initialValue: searchText)
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = PickerLayout(width: proxy.size.width)
            VStack(spacing: 0) {
                PickerHeader(isConnected: app.access.canRead, margin: layout.margin, showsDivider: isScrolled && app.access.canRead)
                page(layout)
            }
        }
        .background(Palette.ground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden()
        .onChange(of: app.path.isEmpty) { _, isOnTop in
            // An album opened while typing: back on the picker, Return starts sorting again.
            if !isOnTop { isSearchFocused = false }
        }
    }

    @ViewBuilder
    private func page(_ layout: PickerLayout) -> some View {
        switch app.access {
        case .authorized, .limited:
            AlbumGridPage(
                layout: layout,
                isScrolled: $isScrolled,
                searchText: $searchText,
                sortOrder: $sortOrder,
                isSearchFocused: $isSearchFocused
            )
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // Return in the search field ends the search; it doesn't start sorting.
                PickerBottomBar(layout: layout, acceptsReturn: !isSearchFocused)
            }
        case .notDetermined:
            PickerMessagePage(layout: layout) {
                WaitingForAccessView()
            }
        case .denied, .restricted:
            PickerMessagePage(layout: layout) {
                AccessNeededView(access: app.access)
            }
        }
    }
}

/// The wordmark on the left and the Photos connection on the right. A hairline appears once
/// content scrolls under it.
private struct PickerHeader: View {
    let isConnected: Bool
    let margin: CGFloat
    let showsDivider: Bool

    var body: some View {
        HStack(spacing: 16) {
            Wordmark()
            Spacer(minLength: 0)
            if isConnected {
                OpenPhotosButton()
            } else {
                Text("Not connected")
                    .font(.meta)
                    .foregroundStyle(Palette.textMuted)
                    .lineLimit(1)
            }
        }
        .padding(.trailing, margin)
        .leadingPaddingClearingWindowControls(margin)
        .frame(height: Metrics.topBarHeight)
        .background(Palette.ground.ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) {
            Hairline()
                .opacity(showsDivider ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: showsDivider)
        }
    }
}

/// "Connected to Photos" with a small arrow: opens the Photos app. If iPadOS can't open it, a
/// toast says so and Piq stays as it is.
///
/// VoiceOver reads "Connected to Photos, opens Photos": it starts with the words on screen, so
/// Voice Control's "Tap Connected to Photos" works (as do "Open Photos" and "Photos"), keeps the
/// connection status, and says that it leaves Piq even with hints turned off.
struct OpenPhotosButton: View {
    /// The URL scheme the Photos app answers to (not documented, but long-standing; checked on
    /// iPadOS 26.5). Opening it needs no `LSApplicationQueriesSchemes` entry; only `canOpenURL`
    /// would, and Piq doesn't ask: the open call itself says whether it worked.
    static let photosURL = URL(string: "photos-redirect://")

    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button(action: openPhotos) {
            HStack(spacing: 5) {
                Text("Connected to Photos")
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.quietLink)
        .contentShape(.hoverEffect, Capsule().inset(by: -8))
        .hoverEffect(.highlight)
        .accessibilityLabel("Connected to Photos, opens Photos")
        .accessibilityInputLabels(["Connected to Photos", "Open Photos", "Photos"])
        .accessibilityIdentifier(A11yID.Picker.openPhotos)
    }

    private func openPhotos() {
        guard let url = Self.photosURL else { return }
        openURL(url) { opened in
            if !opened {
                app.toasts.show("Photos couldn't be opened", systemImage: "exclamationmark.circle")
            }
        }
    }
}

/// "Which album are we sorting?" and the line explaining the swipes; on the album page, the
/// search and sort tools beside or under them (see `PickerIntroLayout`).
struct PickerIntro<Tools: View>: View {
    @ViewBuilder let tools: Tools

    var body: some View {
        PickerIntroLayout {
            Text("Which album are we sorting?")
                .font(.screenTitle)
                .foregroundStyle(Palette.text)
                .accessibilityAddTraits(.isHeader)
            Text("Piq shows each photo full screen. Swipe left to mark it for deletion, swipe right to keep it.")
                .font(.lead)
                .foregroundStyle(Palette.textMuted)
            tools
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension PickerIntro where Tools == EmptyView {
    init() {
        tools = EmptyView()
    }
}

#if DEBUG
#Preview("Albums", traits: .landscapeLeft) {
    AlbumPickerScreen()
        .environment(PreviewSupport.appModel(.albums))
}

#Preview("Resume", traits: .landscapeLeft) {
    AlbumPickerScreen()
        .environment(PreviewSupport.appModel(.resume))
}

#Preview("All sorted, trash not emptied", traits: .landscapeLeft) {
    AlbumPickerScreen()
        .environment(PreviewSupport.appModel(.review))
}

#Preview("Limited access", traits: .landscapeLeft) {
    AlbumPickerScreen()
        .environment(PreviewSupport.appModel(.albums, access: .limited))
}

#Preview("Denied", traits: .landscapeLeft) {
    AlbumPickerScreen()
        .environment(PreviewSupport.appModel(.albums, access: .denied))
}

#Preview("Restricted", traits: .landscapeLeft) {
    AlbumPickerScreen()
        .environment(PreviewSupport.appModel(.albums, access: .restricted))
}

#Preview("Waiting for access", traits: .landscapeLeft) {
    AlbumPickerScreen()
        .environment(PreviewSupport.appModel(nil, access: .notDetermined))
}

#Preview("Loading", traits: .landscapeLeft) {
    AlbumPickerScreen()
        .environment(PreviewSupport.appModel(nil))
}

#Preview("Portrait", traits: .portrait) {
    AlbumPickerScreen()
        .environment(PreviewSupport.appModel(.resume))
}

#Preview("Narrow", traits: .fixedLayout(width: 600, height: 834)) {
    AlbumPickerScreen()
        .environment(PreviewSupport.appModel(.resume))
}

#Preview("Largest text", traits: .fixedLayout(width: 600, height: 834)) {
    AlbumPickerScreen()
        .environment(PreviewSupport.appModel(.resume))
        .dynamicTypeSize(.xxLarge)
}

#Preview("Search", traits: .landscapeLeft) {
    AlbumPickerScreen(searchText: "is")
        .environment(PreviewSupport.appModel(.resume))
}

#Preview("Search hides the selection", traits: .portrait) {
    AlbumPickerScreen(searchText: "lisbon")
        .environment(PreviewSupport.appModel(.resume))
}

#Preview("Search, no matches", traits: .landscapeLeft) {
    AlbumPickerScreen(searchText: "Kyoto")
        .environment(PreviewSupport.appModel(.resume))
}

#Preview("Search, narrow", traits: .fixedLayout(width: 375, height: 834)) {
    AlbumPickerScreen(searchText: "a")
        .environment(PreviewSupport.appModel(.resume))
}

#Preview("Sorted by date created", traits: .landscapeLeft) {
    AlbumPickerScreen()
        .environment(PreviewSupport.appModel(.resume))
        .defaultAppStorage(PickerPreviewDefaults.sortedByDate)
}

#Preview("Sorted by date created, largest text", traits: .fixedLayout(width: 834, height: 1194)) {
    AlbumPickerScreen()
        .environment(PreviewSupport.appModel(.resume))
        .defaultAppStorage(PickerPreviewDefaults.sortedByDate)
        .dynamicTypeSize(.xxLarge)
}

/// User defaults for previews that start sorted by date created.
private enum PickerPreviewDefaults {
    static var sortedByDate: UserDefaults {
        let defaults = UserDefaults(suiteName: "PiqPreview.sortedByDate") ?? .standard
        defaults.set(AlbumSortOrder.dateCreated.rawValue, forKey: AlbumSortOrder.storageKey)
        return defaults
    }
}
#endif
