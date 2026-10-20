import XCTest
@testable import Piq

/// Changes made in Photos while a sorting or review screen is open: photos deleted or added,
/// the whole album deleted or renamed. `LibraryChangeTests` covers the sessions themselves.
@MainActor
final class StateLibraryChangeTests: XCTestCase {
    // MARK: Sorting

    func testWhenTheLastPhotoLeftToSortIsDeletedTheSessionIsDone() async throws {
        let (app, library) = try await startedApp()
        let family = try album("Family", in: app)
        await app.openAlbum(family)
        let session = try XCTUnwrap(app.activeSession)
        session.sortNext(Array(repeating: .keep, count: 16) + [.delete])
        let last = try XCTUnwrap(session.state.currentAssetID)

        library.remove([last])

        await pollUntil("the deleted photo leaves the queue") { session.state.isComplete }
        XCTAssertEqual(session.state.total, 17)
        XCTAssertEqual(session.state.markedCount, 1)
        XCTAssertEqual(app.path, [.sorting(albumID: family.id)], "the screen stays, now showing that everything is sorted")
        XCTAssertNil(session.decide(.keep, for: last), "a swipe under way for the deleted photo lands nowhere")
        XCTAssertEqual(try savedSessions(in: app.container).first?.state, session.state)
    }

    func testNewPhotosAddedWhileSortingAreQueuedAfterTheOthers() async throws {
        let (app, library) = try await startedApp()
        let lisbon = try album("Weekend in Lisbon", in: app)
        await app.openAlbum(lisbon)
        let session = try XCTUnwrap(app.activeSession)
        session.sortNext([.keep, .delete, .keep, .keep, .keep])
        let current = session.state.currentAssetID

        let added = library.addPhotos(3, toAlbum: lisbon.id)

        await pollUntil("the new photos are queued") { session.state.total == 39 }
        XCTAssertEqual(Array(session.state.assetIDs.suffix(3)), added)
        XCTAssertEqual(session.state.currentAssetID, current, "the photo on screen doesn't change")
        XCTAssertEqual(session.state.position, 6)
        XCTAssertEqual(app.path, [.sorting(albumID: lisbon.id)])
        XCTAssertEqual(app.resumePoint(for: lisbon.id), ResumePoint(position: 6, total: 39, markedCount: 1, isComplete: false))
        XCTAssertEqual(try savedSessions(in: app.container).first?.state, session.state)
    }

    func testTheAlbumDeletedWhileSortingGoesBackToTheAlbums() async throws {
        let (app, library) = try await startedApp()
        let iceland = try album("Iceland 2026", in: app)
        await app.openAlbum(iceland)
        try XCTUnwrap(app.activeSession).sortNext([.keep, .delete, .keep])
        let saved = try savedSessions(in: app.container)

        library.removeAlbum(iceland.id)

        await pollUntil("back to the albums") { app.path.isEmpty }
        XCTAssertEqual(app.toasts.current?.message, "Iceland 2026 is no longer in Photos")
        XCTAssertFalse(app.albums.contains { $0.id == iceland.id })
        XCTAssertNotEqual(app.selectedAlbumID, iceland.id)
        XCTAssertEqual(try savedSessions(in: app.container), saved, "its session is left as it was")
    }

    // MARK: Review

    /// The grid, the counts and the selection all follow when a photo in the trash is deleted
    /// in Photos while the review screen is open.
    func testAPhotoInTheTrashDeletedElsewhereWhileReviewing() async throws {
        let (app, library) = try await startedApp()
        let lisbon = try album("Weekend in Lisbon", in: app)
        await app.openAlbum(lisbon)
        let session = try XCTUnwrap(app.activeSession)
        let ids = session.state.assetIDs
        session.sortNext([.delete, .keep, .delete, .delete, .keep])
        app.showReview()
        let review = ReviewModel(selection: [ids[0], ids[3]])

        library.remove([ids[0]])

        await pollUntil("the photo leaves the trash") { !session.state.markedIDs.contains(ids[0]) }
        // What the review screen does when the trash changes.
        review.trashChanged(to: session.state.markedIDs)
        XCTAssertEqual(session.state.markedInOrder, [ids[2], ids[3]], "the grid")
        XCTAssertEqual(session.state.sortedCount, 4)
        XCTAssertEqual(session.state.keptCount, 2)
        XCTAssertEqual(session.state.markedCount, 2)
        XCTAssertEqual(session.state.total, 35)
        XCTAssertEqual(review.selection, [ids[3]])
        XCTAssertEqual(app.path, [.sorting(albumID: lisbon.id), .review(albumID: lisbon.id)], "the review screen stays")
        XCTAssertEqual(try savedSessions(in: app.container).first?.state, session.state)
    }

    func testTheAlbumDeletedWhileReviewingGoesBackToTheAlbums() async throws {
        let (app, library) = try await startedApp()
        let family = try album("Family", in: app)
        await app.openAlbum(family)
        try XCTUnwrap(app.activeSession).sortNext((0..<18).map { $0 < 2 ? .delete : .keep })
        app.showReview()
        let saved = try savedSessions(in: app.container)

        library.removeAlbum(family.id)

        await pollUntil("back to the albums") { app.path.isEmpty }
        XCTAssertEqual(app.toasts.current?.message, "Family is no longer in Photos")
        XCTAssertFalse(app.albums.contains { $0.id == family.id })
        XCTAssertEqual(try savedSessions(in: app.container), saved, "its session is left as it was")
    }

    func testPhotosAddedToAFinishedSessionOpenItsQueueAgain() async throws {
        let (app, library) = try await startedApp()
        let family = try album("Family", in: app)
        await app.openAlbum(family)
        let session = try XCTUnwrap(app.activeSession)
        session.sortNext((0..<18).map { $0 < 2 ? .delete : .keep })
        app.showReview()

        library.addPhotos(2, toAlbum: family.id)

        await pollUntil("the new photos are queued") { !session.state.isComplete }
        XCTAssertEqual(session.state.remainingCount, 2)
        // The review screen's back button now reads "Continue sorting".
        app.continueSorting()
        XCTAssertEqual(app.path, [.sorting(albumID: family.id)])
    }

    // MARK: Renaming

    func testAnAlbumRenamedInPhotosIsRenamedInItsSession() async throws {
        let library = StubPhotoLibrary()
        let trip = AlbumSummary(id: "trip", title: "Trip", kind: .user, photoCount: 2, coverAssetID: "t2")
        library.albums = [trip]
        library.albumContents = [trip.id: ["t1", "t2"]]
        let app = AppModel(library: library, images: SpyImageSource(), container: PreviewSupport.inMemoryContainer())
        await app.start()
        await app.openAlbum(trip)
        let session = try XCTUnwrap(app.activeSession)

        library.albums = [AlbumSummary(id: trip.id, title: "Iceland, May 2026", kind: .user, photoCount: 2, coverAssetID: "t2")]
        await app.reloadAlbums()

        XCTAssertEqual(session.albumTitle, "Iceland, May 2026")
        XCTAssertEqual(try savedSessions(in: app.container).first?.albumTitle, "Iceland, May 2026")
        XCTAssertEqual(app.path, [.sorting(albumID: trip.id)])
    }
}
