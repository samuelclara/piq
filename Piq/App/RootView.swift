import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var app = app
        NavigationStack(path: $app.path) {
            AlbumPickerScreen()
                .navigationDestination(for: Route.self) { route in
                    destination(for: route)
                }
        }
        .toastOverlay(app.toasts)
        .background(Palette.ground.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(Palette.sky)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .task { await app.start() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task { await app.refreshAccess() }
            case .background:
                app.saveNow()
            default:
                break
            }
        }
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .sorting(let albumID):
            if let session = app.activeSession, session.albumID == albumID {
                SortingScreen(session: session)
            } else {
                MissingSessionView()
            }
        case .review(let albumID):
            if let session = app.activeSession, session.albumID == albumID {
                ReviewScreen(session: session)
            } else {
                MissingSessionView()
            }
        }
    }
}

/// Shown if a route outlives its session (shouldn't happen in practice).
private struct MissingSessionView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 20) {
            Text("This album isn't open anymore")
                .font(.dialogTitle)
                .foregroundStyle(Palette.text)
            Button("Back to albums") { app.returnToAlbums() }
                .buttonStyle(.pill(.primary, height: Metrics.largeButtonHeight, font: .largeButtonLabel))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.ground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// Accessibility identifiers shared by the views and the UI tests.
enum A11yID {
    enum Picker {
        static let grid = "picker.grid"
        static let startButton = "picker.start"
        static let openSettings = "picker.openSettings"
        static let changeSelection = "picker.changeSelection"
        /// One per album tile.
        static func album(_ title: String) -> String { "picker.album.\(title)" }
    }

    enum Sorting {
        static let back = "sorting.back"
        static let counter = "sorting.counter"
        static let undo = "sorting.undo"
        static let review = "sorting.review"
        static let photo = "sorting.photo"
        static let delete = "sorting.delete"
        static let keep = "sorting.keep"
    }

    enum Review {
        static let back = "review.back"
        static let summary = "review.summary"
        static let selectAll = "review.selectAll"
        static let restore = "review.restore"
        static let emptyTrash = "review.emptyTrash"
        static let confirmDelete = "review.confirmDelete"
        static let cancelDelete = "review.cancelDelete"
        static let emptyState = "review.emptyState"
        static let emptyStateButton = "review.emptyStateButton"
        static let closePreview = "review.closePreview"
        static let previewPhoto = "review.previewPhoto"
        /// One per thumbnail.
        static func tile(_ assetID: String) -> String { "review.tile.\(assetID)" }
    }

    static let toast = "toast"
}
