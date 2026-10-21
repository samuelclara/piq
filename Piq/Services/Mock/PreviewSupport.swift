#if DEBUG
import SwiftData
import SwiftUI

/// Ready-made app states over the mock library, for SwiftUI previews and mock launches.
@MainActor
enum PreviewSupport {
    enum Scenario: String {
        /// Album picker, nothing started.
        case albums
        /// Album picker with "Iceland 2026" selected and a session at 38 of 400.
        case resume
        /// Sorting "Iceland 2026" at 38 of 400.
        case sorting
        /// Sorting "Iceland 2026" from its first photo, nothing decided yet.
        case sortingStart
        /// Review after sorting all 400 photos (1 in 8 marked).
        case review
        /// Review part-way through: 120 of 400 sorted.
        case reviewPartial
        /// Review with an empty trash.
        case emptyTrash
    }

    /// Where a mock app model keeps its sessions.
    enum Persistence {
        /// Gone with the app model: previews, unit tests and plain mock launches.
        case inMemory
        /// `PiqMock.store` in Application Support, apart from the real store, so UI tests can quit
        /// and relaunch Piq. The mock library then remembers what was deleted from it too.
        /// `reset` starts both over.
        case onDisk(reset: Bool)
    }

    /// An app model over the mock library. With a scenario it is already loaded (albums listed,
    /// session seeded, screen pushed); without one it loads normally when the root view appears.
    /// An on-disk store that already has the scenario's session keeps it as it is.
    static func appModel(
        _ scenario: Scenario? = .albums,
        access: LibraryAccess = .authorized,
        fullImageLatency: Duration = .zero,
        deletion: MockPhotoLibrary.DeletionBehavior = .succeed,
        deletionDelay: Duration = MockPhotoLibrary.defaultDeletionDelay,
        persistence: Persistence = .inMemory
    ) -> AppModel {
        let library: MockPhotoLibrary
        let container: ModelContainer
        switch persistence {
        case .inMemory:
            library = MockPhotoLibrary(access: access)
            container = inMemoryContainer()
        case .onDisk(let reset):
            if reset {
                MockPhotoLibrary.forgetRememberedChanges()
            }
            library = MockPhotoLibrary(access: access, remembersChanges: true)
            container = onDiskContainer(reset: reset)
        }
        library.deletionBehavior = deletion
        library.deletionDelay = deletionDelay
        let images = MockImageSource(library: library, fullImageLatency: fullImageLatency)
        let app = AppModel(library: library, images: images, container: container)
        guard let scenario else { return app }

        app.preparePreview(albums: library.albumSummaries())
        guard let album = library.album(MockPhotoLibrary.icelandAlbumID) else { return app }
        let ids = library.photoIDs(inAlbum: album.id)
        // Mark the out-of-focus shots, about 1 in 8 photos, as in real life.
        let decide: (String) -> SwipeAction = { id in
            let name = library.imageName(for: id)
            return name == "MockPhoto14" || name == "MockPhoto16" ? .delete : .keep
        }
        switch scenario {
        case .albums:
            break
        case .resume:
            app.preparePreviewSession(album: album, assetIDs: ids, sortedCount: 37, decide: decide)
        case .sorting:
            app.preparePreviewSession(album: album, assetIDs: ids, sortedCount: 37, decide: decide)
            app.path = [.sorting(albumID: album.id)]
        case .sortingStart:
            app.preparePreviewSession(album: album, assetIDs: ids, sortedCount: 0, decide: decide)
            app.path = [.sorting(albumID: album.id)]
        case .review:
            app.preparePreviewSession(album: album, assetIDs: ids, sortedCount: ids.count, decide: decide)
            app.path = [.review(albumID: album.id)]
        case .reviewPartial:
            app.preparePreviewSession(album: album, assetIDs: ids, sortedCount: 120, decide: decide)
            app.path = [.sorting(albumID: album.id), .review(albumID: album.id)]
        case .emptyTrash:
            app.preparePreviewSession(album: album, assetIDs: ids, sortedCount: 40) { _ in .keep }
            app.path = [.sorting(albumID: album.id), .review(albumID: album.id)]
        }
        return app
    }

    /// The active session of a scenario's app model.
    static func session(_ scenario: Scenario) -> (AppModel, SessionController) {
        let app = appModel(scenario)
        guard let session = app.activeSession else {
            fatalError("Scenario \(scenario) has no session")
        }
        return (app, session)
    }

    /// Steps `session` back with Previous to the nearest photo decided `action` (for previews of a
    /// revisited photo and its tag).
    static func stepBack(_ session: SessionController, toPhotoDecided action: SwipeAction) {
        while session.step(.previous) {
            if let id = session.state.currentAssetID, session.state.verdict(for: id)?.action == action {
                return
            }
        }
    }

    static func inMemoryContainer() -> ModelContainer {
        do {
            return try SessionStore.makeContainer(ModelConfiguration(isStoredInMemoryOnly: true))
        } catch {
            fatalError("Couldn't create an in-memory SwiftData store: \(error)")
        }
    }

    /// The store of mock launches with `-PiqMockPersistentStore`: `PiqMock.store` in Application
    /// Support, next to (and apart from) the real `default.store`. `reset` deletes it first.
    static func onDiskContainer(reset: Bool) -> ModelContainer {
        let folder = URL.applicationSupportDirectory
        let name = "PiqMock.store"
        if reset {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(at: folder.appending(path: name + suffix))
            }
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return try SessionStore.makeContainer(ModelConfiguration(url: folder.appending(path: name), cloudKitDatabase: .none))
        } catch {
            fatalError("Couldn't open the mock session store: \(error)")
        }
    }
}
#endif
