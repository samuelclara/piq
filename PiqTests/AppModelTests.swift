import SwiftData
import XCTest
@testable import Piq

@MainActor
final class AppModelTests: XCTestCase {
    // MARK: Starting

    func testStartListsRecentsAndFavoritesThenTheUserAlbums() async throws {
        let app = PreviewSupport.appModel(nil)
        XCTAssertFalse(app.hasLoadedAlbums)
        XCTAssertTrue(app.albums.isEmpty)

        await app.start()

        XCTAssertEqual(app.access, .authorized)
        XCTAssertTrue(app.hasLoadedAlbums)
        XCTAssertFalse(app.isLoadingAlbums)
        XCTAssertEqual(app.albums.map(\.title), ["Recents", "Favorites", "Iceland 2026", "Weekend in Lisbon", "Family", "Drafts"])
        XCTAssertEqual(app.albums.map(\.kind), [.recents, .favorites, .user, .user, .user, .user])
        XCTAssertEqual(app.albums.dropFirst(2).map(\.photoCount), [400, 36, 18, 0])
        XCTAssertEqual(app.albums.first?.photoCount, 454, "Recents holds every photo")
        let library = try mockLibrary(of: app)
        for album in app.albums {
            XCTAssertEqual(album.coverAssetID, library.photoIDs(inAlbum: album.id).last, "\(album.title): the cover is the newest photo")
        }
    }

    func testStartAsksForAccessOnFirstLaunch() async {
        let app = PreviewSupport.appModel(nil, access: .notDetermined)
        XCTAssertEqual(app.access, .notDetermined)

        await app.start()

        XCTAssertEqual(app.access, .authorized)
        XCTAssertEqual(app.albums.count, 6)
    }

    func testEveryAnswerToTheFirstLaunchPromptIsHandled() async {
        for answer in [LibraryAccess.authorized, .limited, .denied] {
            let library = StubPhotoLibrary()
            library.access = .notDetermined
            library.answerToAccessRequest = answer
            library.albums = [AlbumSummary(id: "recents", title: "Recents", kind: .recents, photoCount: 1, coverAssetID: "p1")]
            let app = AppModel(library: library, images: SpyImageSource(), container: PreviewSupport.inMemoryContainer())

            await app.start()

            XCTAssertEqual(app.access, answer)
            XCTAssertTrue(app.hasLoadedAlbums, "\(answer)")
            XCTAssertEqual(app.albums.count, answer.canRead ? 1 : 0, "\(answer): albums only with access")
        }
    }

    func testStartWithoutAccessListsNoAlbums() async {
        for access in [LibraryAccess.denied, .restricted] {
            let app = PreviewSupport.appModel(nil, access: access)
            await app.start()
            XCTAssertEqual(app.access, access)
            XCTAssertTrue(app.albums.isEmpty, "\(access)")
            XCTAssertTrue(app.hasLoadedAlbums, "\(access): the picker explains instead of loading forever")
        }
    }

    func testLimitedAccessListsOnlyTheSmartAlbumsOfTheAllowedPhotos() async {
        let app = PreviewSupport.appModel(nil, access: .limited)
        await app.start()

        XCTAssertEqual(app.access, .limited)
        XCTAssertEqual(app.albums.map(\.title), ["Recents", "Favorites"])
        XCTAssertEqual(app.albums.first?.photoCount, 36)
    }

    func testRefreshAccessPicksUpAChangeMadeInSettings() async throws {
        let (app, library) = try await startedApp()

        library.access = .denied
        await app.refreshAccess()
        XCTAssertEqual(app.access, .denied)
        XCTAssertTrue(app.albums.isEmpty)

        library.access = .authorized
        await app.refreshAccess()
        XCTAssertEqual(app.access, .authorized)
        XCTAssertEqual(app.albums.count, 6)
    }

    // MARK: Opening albums

    func testOpeningANewAlbumStartsSortingIt() async throws {
        let (app, library) = try await startedApp()
        let iceland = try album("Iceland 2026", in: app)

        await app.openAlbum(iceland)

        XCTAssertEqual(app.path, [.sorting(albumID: iceland.id)])
        XCTAssertFalse(app.isOpeningAlbum)
        let session = try XCTUnwrap(app.activeSession)
        XCTAssertEqual(session.albumID, iceland.id)
        XCTAssertEqual(session.albumTitle, "Iceland 2026")
        XCTAssertEqual(session.state.assetIDs, library.photoIDs(inAlbum: iceland.id))
        let metadata = await library.metadata(for: session.state.assetIDs)
        let dates = session.state.assetIDs.compactMap { metadata[$0]?.creationDate }
        XCTAssertEqual(dates.count, 400)
        XCTAssertEqual(dates, dates.sorted(), "oldest first")
        XCTAssertEqual(session.state.position, 1)
        XCTAssertEqual(session.state.total, 400)
        XCTAssertEqual(try savedSessions(in: app.container), [SavedSession(albumID: iceland.id, albumTitle: "Iceland 2026", state: session.state)])
        XCTAssertNotNil(app.sessions[iceland.id])
        XCTAssertNil(app.resumePoint(for: iceland.id), "nothing sorted yet, so the picker still offers Start sorting")
    }

    func testReopeningAnAlbumResumesWhereItLeftOff() async throws {
        let (app, _) = try await startedApp()
        let lisbon = try album("Weekend in Lisbon", in: app)
        await app.openAlbum(lisbon)
        let first = try XCTUnwrap(app.activeSession)
        first.sortNext([.keep, .delete, .keep, .keep, .delete])
        let progress = first.state

        app.returnToAlbums()
        XCTAssertEqual(app.resumePoint(for: lisbon.id), ResumePoint(position: 6, total: 36, markedCount: 2, isComplete: false))

        await app.openAlbum(lisbon)

        XCTAssertEqual(app.path, [.sorting(albumID: lisbon.id)])
        let resumed = try XCTUnwrap(app.activeSession)
        XCTAssertEqual(resumed.state, progress)
        XCTAssertEqual(resumed.state.position, 6)
        XCTAssertEqual(try savedSessions(in: app.container).count, 1, "still one session per album")
    }

    func testAFinishedSessionWithPhotosInTheTrashOpensOnReview() async throws {
        let (app, _) = try await startedApp()
        let family = try album("Family", in: app)
        try await sortEverything(in: family, of: app, marking: 3)
        app.returnToAlbums()
        XCTAssertEqual(app.resumePoint(for: family.id), ResumePoint(position: 18, total: 18, markedCount: 3, isComplete: true))

        await app.openAlbum(family)

        XCTAssertEqual(app.path, [.review(albumID: family.id)])
        XCTAssertEqual(app.activeSession?.state.markedCount, 3)
    }

    func testAFinishedSessionWithAnEmptyTrashStartsOver() async throws {
        let (app, _) = try await startedApp()
        let family = try album("Family", in: app)
        try await sortEverything(in: family, of: app, marking: 0)
        app.returnToAlbums()
        XCTAssertNil(app.resumePoint(for: family.id), "nothing left to resume")

        await app.openAlbum(family)

        XCTAssertEqual(app.path, [.sorting(albumID: family.id)])
        let session = try XCTUnwrap(app.activeSession)
        XCTAssertEqual(session.state.sortedCount, 0)
        XCTAssertEqual(session.state.total, 18)
        XCTAssertEqual(try savedSessions(in: app.container).map(\.state), [session.state])
    }

    func testAnAlbumWhoseTrashWasEmptiedStartsOverWithTheRemainingPhotos() async throws {
        let (app, _) = try await startedApp()
        let family = try album("Family", in: app)
        let session = try await sortEverything(in: family, of: app, marking: 3)
        let outcome = await session.emptyTrash()
        XCTAssertEqual(outcome, .deleted(count: 3, undeletable: 0))
        await pollUntil("the album list catches up with the deletion") {
            app.albums.first { $0.id == family.id }?.photoCount == 15
        }
        app.returnToAlbums()
        XCTAssertNil(app.resumePoint(for: family.id))

        await app.openAlbum(family)

        XCTAssertEqual(app.path, [.sorting(albumID: family.id)])
        XCTAssertEqual(app.activeSession?.state.total, 15)
        XCTAssertEqual(app.activeSession?.state.sortedCount, 0)
    }

    func testAnEmptyAlbumShowsAToastInsteadOfOpening() async throws {
        let (app, _) = try await startedApp()
        let drafts = try album("Drafts", in: app)

        await app.openAlbum(drafts)

        XCTAssertEqual(app.path, [])
        XCTAssertNil(app.activeSession)
        XCTAssertEqual(app.toasts.current?.message, "There are no photos in Drafts")
        XCTAssertTrue(try savedSessions(in: app.container).isEmpty, "no session for an empty album")
        XCTAssertFalse(app.isOpeningAlbum)
    }

    func testAnAlbumThatNoLongerExistsShowsAToastAndLeavesTheList() async throws {
        let library = StubPhotoLibrary()
        let family = AlbumSummary(id: "family", title: "Family", kind: .user, photoCount: 2, coverAssetID: "f2")
        let oldTrip = AlbumSummary(id: "old-trip", title: "Old trip", kind: .user, photoCount: 2, coverAssetID: "o2")
        library.albums = [family, oldTrip]
        library.albumContents = [family.id: ["f1", "f2"], oldTrip.id: ["o1", "o2"]]
        let app = AppModel(library: library, images: SpyImageSource(), container: PreviewSupport.inMemoryContainer())
        await app.start()
        XCTAssertEqual(app.albums.map(\.id), [family.id, oldTrip.id])
        // The person picks Old trip, which was just deleted in Photos.
        app.selectedAlbumID = oldTrip.id
        library.albums = [family]
        library.albumContents[oldTrip.id] = nil

        await app.openAlbum(oldTrip)

        XCTAssertEqual(app.toasts.current?.message, "That album is no longer in Photos")
        XCTAssertEqual(app.albums.map(\.id), [family.id], "the album list was reloaded without it")
        XCTAssertNil(app.selectedAlbumID, "the deleted album is no longer selected")
        XCTAssertEqual(app.path, [])
        XCTAssertNil(app.activeSession)
        XCTAssertTrue(try savedSessions(in: app.container).isEmpty)
        XCTAssertFalse(app.isOpeningAlbum)
    }

    // MARK: Navigation

    func testShowReviewPushesReviewOnTopOfSortingOnce() async throws {
        let (app, _) = try await startedApp()
        let lisbon = try album("Weekend in Lisbon", in: app)
        await app.openAlbum(lisbon)

        app.showReview()
        XCTAssertEqual(app.path, [.sorting(albumID: lisbon.id), .review(albumID: lisbon.id)])

        app.showReview()
        XCTAssertEqual(app.path, [.sorting(albumID: lisbon.id), .review(albumID: lisbon.id)], "never two review screens")
    }

    func testShowReviewWithoutAnOpenAlbumDoesNothing() async throws {
        let (app, _) = try await startedApp()
        app.showReview()
        XCTAssertEqual(app.path, [])
    }

    func testContinueSortingPopsBackToTheSortingScreenUnderneath() async throws {
        let (app, _) = try await startedApp()
        let lisbon = try album("Weekend in Lisbon", in: app)
        await app.openAlbum(lisbon)
        try XCTUnwrap(app.activeSession).sortNext([.delete, .keep])
        app.showReview()

        app.continueSorting()

        XCTAssertEqual(app.path, [.sorting(albumID: lisbon.id)])
    }

    func testContinueSortingReplacesAReviewScreenThatWasOpenedDirectly() async throws {
        let (app, _) = try await startedApp()
        let family = try album("Family", in: app)
        try await sortEverything(in: family, of: app, marking: 3)
        app.returnToAlbums()
        await app.openAlbum(family)
        XCTAssertEqual(app.path, [.review(albumID: family.id)])
        // A photo added to the album since puts one photo back in the queue.
        let session = try XCTUnwrap(app.activeSession)
        session.reconcile(withAlbumAssetIDs: session.state.assetIDs + ["new-photo"])
        XCTAssertFalse(session.state.isComplete)

        app.continueSorting()

        XCTAssertEqual(app.path, [.sorting(albumID: family.id)])
    }

    func testContinueSortingGoesToTheAlbumsWhenEverythingIsSorted() async throws {
        let (app, _) = try await startedApp()
        let family = try album("Family", in: app)
        try await sortEverything(in: family, of: app, marking: 2)
        app.showReview()
        XCTAssertEqual(app.path, [.sorting(albumID: family.id), .review(albumID: family.id)])

        app.continueSorting()
        XCTAssertEqual(app.path, [])

        // Same from a review screen that was opened directly.
        await app.openAlbum(family)
        XCTAssertEqual(app.path, [.review(albumID: family.id)])
        app.continueSorting()
        XCTAssertEqual(app.path, [])
    }

    func testReturnToAlbumsGoesHomeWithEverythingSaved() async throws {
        let (app, _) = try await startedApp()
        let lisbon = try album("Weekend in Lisbon", in: app)
        await app.openAlbum(lisbon)
        app.showReview()
        let session = try XCTUnwrap(app.activeSession)
        session.sortNext([.keep, .delete])
        XCTAssertEqual(try savedSessions(in: app.container).first?.state, session.state, "each swipe is saved as it lands")

        app.returnToAlbums()

        XCTAssertEqual(app.path, [])
        XCTAssertEqual(try savedSessions(in: app.container).first?.state, session.state)
    }

    func testSaveNowWritesPendingChanges() async throws {
        let (app, _) = try await startedApp()
        let family = try album("Family", in: app)
        await app.openAlbum(family)
        let session = try XCTUnwrap(app.activeSession)
        session.sortNext([.delete, .keep, .keep])

        app.saveNow()

        XCTAssertEqual(try savedSessions(in: app.container).first?.state, session.state)
    }

    // MARK: Selection and relaunch

    func testSelectionSurvivesReloadsAndFallsBackToTheUnfinishedAlbum() async throws {
        let (app, _) = try await startedApp()
        let lisbon = try album("Weekend in Lisbon", in: app)
        let family = try album("Family", in: app)
        await app.openAlbum(lisbon)
        try XCTUnwrap(app.activeSession).sortNext([.keep, .delete])
        app.returnToAlbums()

        app.selectedAlbumID = family.id
        await app.reloadAlbums()
        XCTAssertEqual(app.selectedAlbumID, family.id, "a reload keeps the person's choice")

        app.selectedAlbumID = "an-album-deleted-in-photos"
        await app.reloadAlbums()
        XCTAssertEqual(app.selectedAlbumID, lisbon.id, "falls back to the album with an unfinished session")
    }

    func testSessionsSurviveARelaunch() async throws {
        let url = URL.temporaryDirectory.appending(path: "PiqTests-\(UUID().uuidString).store")
        defer { Self.removeStore(at: url) }
        var progress = SortingState(assetIDs: [])

        do {
            let app = try await launchApp(storeURL: url)
            let family = try album("Family", in: app)
            let lisbon = try album("Weekend in Lisbon", in: app)
            await app.openAlbum(family)
            try XCTUnwrap(app.activeSession).sortNext([.keep, .keep])
            app.returnToAlbums()
            await app.openAlbum(lisbon)
            let session = try XCTUnwrap(app.activeSession)
            session.sortNext([.keep, .delete, .keep, .keep, .delete])
            progress = session.state
            // The app goes to the background and is quit there.
            app.saveNow()
        }

        let app = try await launchApp(storeURL: url)
        let lisbon = try album("Weekend in Lisbon", in: app)
        let family = try album("Family", in: app)
        XCTAssertEqual(app.selectedAlbumID, lisbon.id, "the most recently sorted unfinished album is preselected")
        XCTAssertEqual(app.resumePoint(for: lisbon.id), ResumePoint(position: 6, total: 36, markedCount: 2, isComplete: false))
        XCTAssertEqual(app.resumePoint(for: family.id), ResumePoint(position: 3, total: 18, markedCount: 0, isComplete: false))

        await app.openAlbum(lisbon)

        XCTAssertEqual(app.path, [.sorting(albumID: lisbon.id)])
        XCTAssertEqual(app.activeSession?.state, progress)
    }

    // MARK: Helpers

    /// Opens `album` and sorts every photo in it, marking the first `marked` ones.
    @discardableResult
    private func sortEverything(in album: AlbumSummary, of app: AppModel, marking marked: Int) async throws -> SessionController {
        await app.openAlbum(album)
        let session = try XCTUnwrap(app.activeSession)
        session.sortNext((0..<session.state.total).map { $0 < marked ? .delete : .keep })
        XCTAssertTrue(session.state.isComplete)
        return session
    }

    /// An app model over the mock library with an on-disk store at `url`, started like a launch.
    private func launchApp(storeURL url: URL) async throws -> AppModel {
        let container = try SessionStore.makeContainer(ModelConfiguration(url: url, cloudKitDatabase: .none))
        let library = MockPhotoLibrary()
        let app = AppModel(library: library, images: MockImageSource(library: library), container: container)
        await app.start()
        return app
    }

    private static func removeStore(at url: URL) {
        let folder = url.deletingLastPathComponent()
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: folder.appending(path: url.lastPathComponent + suffix))
        }
    }
}
