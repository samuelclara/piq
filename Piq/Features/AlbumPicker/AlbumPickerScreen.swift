import SwiftUI

/// Screen 1: pick the album to sort. Handles every Photos authorization outcome: a quiet wait
/// while the system asks, an explanation with a way to Settings when access is denied or
/// restricted, and the album grid (with a way to change the selection under limited access).
struct AlbumPickerScreen: View {
    @Environment(AppModel.self) private var app
    @State private var isScrolled = false

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
    }

    @ViewBuilder
    private func page(_ layout: PickerLayout) -> some View {
        switch app.access {
        case .authorized, .limited:
            AlbumGridPage(layout: layout, isScrolled: $isScrolled)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    PickerBottomBar(layout: layout)
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
            Text(isConnected ? "Connected to Photos" : "Not connected")
                .font(.meta)
                .foregroundStyle(Palette.textMuted)
                .lineLimit(1)
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

/// "Which album are we sorting?" and the line explaining the swipes.
struct PickerIntro: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Which album are we sorting?")
                .font(.screenTitle)
                .foregroundStyle(Palette.text)
                .accessibilityAddTraits(.isHeader)
            Text("Piq shows each photo full screen. Swipe left to mark it for deletion, swipe right to keep it.")
                .font(.lead)
                .foregroundStyle(Palette.textMuted)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
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
#endif
