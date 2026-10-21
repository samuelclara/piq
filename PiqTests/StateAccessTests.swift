import XCTest
@testable import Piq

/// Photos access changing while Piq runs: switched off in Settings while a session is open, then
/// back on, and moves between full and limited access. Piq reads the new status when it becomes
/// active again (`refreshAccess`), which these tests call directly.
@MainActor
final class StateAccessTests: XCTestCase {
    // MARK: Losing access

    func testLosingAccessWhileSortingGoesBackToThePickerAndKeepsEverySession() async throws {
        let (app, library) = try await startedApp()
        let family = try album("Family", in: app)
        let lisbon = try album("Weekend in Lisbon", in: app)
        await app.openAlbum(family)
        try XCTUnwrap(app.activeSession).sortNext([.keep, .delete])
        app.returnToAlbums()
        await app.openAlbum(lisbon)
        let session = try XCTUnwrap(app.activeSession)
        session.sortNext([.keep, .delete, .keep])
        let progress = session.state
        let saved = try savedSessions(in: app.container)

        // The person sets Photos access to None in Settings and comes back to Piq.
        library.access = .denied
        await app.refreshAccess()

        XCTAssertEqual(app.access, .denied)
        XCTAssertEqual(app.path, [], "back to the picker, which explains how to give access again")
        XCTAssertTrue(app.albums.isEmpty)
        XCTAssertEqual(try savedSessions(in: app.container), saved, "every session stays as it was")
        XCTAssertEqual(app.selectedAlbumID, lisbon.id)

        // Access comes back.
        library.access = .authorized
        await app.refreshAccess()

        XCTAssertEqual(app.selectedAlbumID, lisbon.id, "the album that was open is selected, ready to resume")
        XCTAssertEqual(app.resumePoint(for: lisbon.id), ResumePoint(position: 4, total: 36, markedCount: 1, isComplete: false))
        XCTAssertEqual(app.resumePoint(for: family.id), ResumePoint(position: 3, total: 18, markedCount: 1, isComplete: false))
        XCTAssertEqual(try savedSessions(in: app.container), saved)

        await app.openAlbum(lisbon)
        XCTAssertEqual(app.path, [.sorting(albumID: lisbon.id)])
        XCTAssertTrue(app.activeSession === session)
        XCTAssertEqual(session.state, progress)
    }

    func testLosingAccessWhileReviewingGoesBackToThePicker() async throws {
        let (app, library) = try await startedApp()
        let family = try album("Family", in: app)
        await app.openAlbum(family)
        let session = try XCTUnwrap(app.activeSession)
        session.sortNext((0..<18).map { $0 < 3 ? .delete : .keep })
        app.showReview()
        XCTAssertEqual(app.path, [.sorting(albumID: family.id), .review(albumID: family.id)])
        let saved = try savedSessions(in: app.container)

        library.access = .restricted
        await app.refreshAccess()

        XCTAssertEqual(app.path, [])
        XCTAssertEqual(try savedSessions(in: app.container), saved)

        library.access = .authorized
        await app.refreshAccess()
        XCTAssertEqual(app.resumePoint(for: family.id), ResumePoint(position: 18, total: 18, markedCount: 3, isComplete: true))
        await app.openAlbum(family)
        XCTAssertEqual(app.path, [.review(albumID: family.id)], "a finished session opens on its trash")
    }

    /// The person empties the trash and, while the system prompt is up, switches Photos access
    /// off. By the time Photos answers it can't see a single photo, which says nothing about
    /// whether they are gone: the trash stays as it was, and is still there once access is back.
    func testLosingAccessWhileTheSystemPromptIsUpKeepsTheTrash() async throws {
        let app = PreviewSupport.appModel(nil, deletionDelay: .milliseconds(1500))
        await app.start()
        let library = try mockLibrary(of: app)
        let family = try album("Family", in: app)
        await app.openAlbum(family)
        let session = try XCTUnwrap(app.activeSession)
        session.sortNext((0..<18).map { $0 < 3 ? .delete : .keep })
        app.showReview()
        let sorted = session.state

        let emptying = Task { await session.emptyTrash() }
        await pollUntil("the system prompt is up") { session.isEmptyingTrash }
        library.access = .denied
        await app.refreshAccess()
        XCTAssertEqual(app.path, [], "back to the picker, which explains")
        XCTAssertTrue(session.isEmptyingTrash, "the prompt is still up")
        let outcome = await emptying.value

        XCTAssertEqual(outcome, .deleted(count: 0, undeletable: 3), "reported as not deleted")
        XCTAssertEqual(session.state, sorted, "the trash and the undo history are unchanged")
        library.access = .authorized
        await app.refreshAccess()
        XCTAssertEqual(session.state, sorted, "nothing comes back as unsorted")
        XCTAssertEqual(app.resumePoint(for: family.id), ResumePoint(position: 18, total: 18, markedCount: 3, isComplete: true))
        XCTAssertEqual(try savedSessions(in: app.container).first?.state, sorted)
    }

    /// Coming back from Settings with access, the picker shows its loading tiles until the albums
    /// arrive, rather than "No albums yet".
    func testRegainingAccessShowsTheAlbumsAsLoading() async {
        let library = StubPhotoLibrary()
        library.albums = [AlbumSummary(id: "trip", title: "Trip", kind: .user, photoCount: 2, coverAssetID: "t2")]
        library.albumContents = ["trip": ["t1", "t2"]]
        let app = AppModel(library: library, images: SpyImageSource(), container: PreviewSupport.inMemoryContainer())
        await app.start()
        library.access = .denied
        await app.refreshAccess()
        XCTAssertTrue(app.hasLoadedAlbums, "the picker explains instead of loading forever")

        let slowListing = Gate()
        library.albumListGate = slowListing
        library.access = .authorized
        let refresh = Task { await app.refreshAccess() }
        await pollUntil("Photos is asked for the albums") { slowListing.isHolding }
        XCTAssertFalse(app.hasLoadedAlbums)
        XCTAssertTrue(app.isLoadingAlbums)

        slowListing.open()
        await refresh.value
        XCTAssertTrue(app.hasLoadedAlbums)
        XCTAssertEqual(app.albums.map(\.id), ["trip"])
    }

    // MARK: Full and limited access

    /// Limited access hides user albums: the one being sorted closes with a word of explanation,
    /// and its session waits, untouched, for full access.
    func testSwitchingToLimitedAccessClosesAUserAlbumAndKeepsItsSession() async throws {
        let (app, library) = try await startedApp()
        let iceland = try album("Iceland 2026", in: app)
        await app.openAlbum(iceland)
        let session = try XCTUnwrap(app.activeSession)
        session.sortNext([.keep, .delete, .keep, .keep, .delete])
        let progress = session.state
        let saved = try savedSessions(in: app.container)

        library.access = .limited
        await app.refreshAccess()

        XCTAssertEqual(app.path, [])
        XCTAssertEqual(app.toasts.current?.message, "Iceland 2026 needs full access to Photos")
        XCTAssertEqual(app.albums.map(\.title), ["Recents", "Favorites"])
        XCTAssertEqual(try savedSessions(in: app.container), saved)
        XCTAssertEqual(session.state, progress)

        library.access = .authorized
        await app.refreshAccess()

        XCTAssertEqual(app.selectedAlbumID, iceland.id)
        XCTAssertEqual(app.resumePoint(for: iceland.id), ResumePoint(position: 6, total: 400, markedCount: 2, isComplete: false))
        await app.openAlbum(iceland)
        XCTAssertTrue(app.activeSession === session)
        XCTAssertEqual(session.state, progress)
    }

    /// What PhotoKit does under limited access: it lists Recents and Favorites only, yet still
    /// answers for a user album, with just the photos the person allowed. The user album being
    /// sorted closes with a word of explanation, and that partial answer never reaches its session.
    func testLimitedAccessClosesAnOpenUserAlbumWithoutTouchingItsSession() async throws {
        let photos = (1...6).map { "t\($0)" }
        let recents = AlbumSummary(id: "recents", title: "Recents", kind: .recents, photoCount: 6, coverAssetID: "t6")
        let trip = AlbumSummary(id: "trip", title: "Trip", kind: .user, photoCount: 6, coverAssetID: "t6")
        let library = StubPhotoLibrary()
        library.albums = [recents, trip]
        library.albumContents = [recents.id: photos, trip.id: photos]
        let app = AppModel(library: library, images: SpyImageSource(), container: PreviewSupport.inMemoryContainer())
        await app.start()
        await app.openAlbum(trip)
        let session = try XCTUnwrap(app.activeSession)
        session.sortNext([.delete, .keep, .delete])
        let progress = session.state

        // Settings, Photos, Limited Access, allowing t2 and t5.
        library.access = .limited
        library.albums = [AlbumSummary(id: recents.id, title: "Recents", kind: .recents, photoCount: 2, coverAssetID: "t5")]
        library.albumContents = [recents.id: ["t2", "t5"], trip.id: ["t2", "t5"]]
        await app.refreshAccess()

        XCTAssertEqual(app.path, [])
        XCTAssertEqual(app.toasts.current?.message, "Trip needs full access to Photos")
        XCTAssertEqual(session.state, progress)
        XCTAssertEqual(try savedSessions(in: app.container).first { $0.albumID == trip.id }?.state, progress)

        library.access = .authorized
        library.albums = [recents, trip]
        library.albumContents = [recents.id: photos, trip.id: photos]
        await app.refreshAccess()

        XCTAssertEqual(app.selectedAlbumID, trip.id)
        await app.openAlbum(trip)
        XCTAssertTrue(app.activeSession === session)
        XCTAssertEqual(session.state, progress)
    }

    /// Recents stays listed under limited access, with only the selected photos. The photos
    /// already sorted (and the trash) stay in the session even if they're hidden now; only the
    /// queue follows what Piq can see. Back with full access, nothing was lost, and the photo on
    /// screen stays on screen, the photos that come back queued after it in album order.
    func testSwitchingToLimitedAndBackKeepsTheSortedPhotosOfASmartAlbum() async throws {
        let (app, library) = try await startedApp()
        let recents = try album("Recents", in: app)
        await app.openAlbum(recents)
        let session = try XCTUnwrap(app.activeSession)
        session.sortNext((0..<40).map { $0 % 8 == 3 ? .delete : .keep })
        let full = session.state
        XCTAssertEqual(full.markedCount, 5)

        library.access = .limited
        await app.refreshAccess()

        XCTAssertEqual(app.path, [.sorting(albumID: recents.id)], "Recents is still listed, so sorting carries on")
        XCTAssertEqual(session.state.history, full.history, "sorted photos stay, hidden or not")
        XCTAssertEqual(session.state.markedIDs, full.markedIDs, "so does the trash")
        // The selection is the first 30 photos and 6 from the second album: the queue is those 6.
        let visible = library.photoIDs(inAlbum: recents.id)
        XCTAssertEqual(session.state.assetIDs, full.history.map(\.assetID) + visible.suffix(6))
        XCTAssertEqual(session.state.currentAssetID, visible[30])
        assertRecord(session.record, matches: session.state)

        library.access = .authorized
        await app.refreshAccess()

        let onScreen = visible[30]
        XCTAssertEqual(session.state.currentAssetID, onScreen, "the photo on screen stays")
        XCTAssertEqual(session.state.history, full.history, "every decision as it was")
        XCTAssertEqual(session.state.decisions, full.decisions)
        XCTAssertEqual(session.state.markedIDs, full.markedIDs, "and the trash")
        XCTAssertEqual(session.state.assetIDs, full.history.map(\.assetID) + [onScreen] + full.assetIDs.dropFirst(40).filter { $0 != onScreen })
        XCTAssertEqual(try savedSessions(in: app.container).first?.state, session.state)
    }

    /// A session started under limited access gets the rest of the album queued once Piq has
    /// full access, without leaving the screen.
    func testSwitchingFromLimitedToFullAccessQueuesTheNewlyVisiblePhotos() async throws {
        let app = PreviewSupport.appModel(nil, access: .limited)
        await app.start()
        let library = try mockLibrary(of: app)
        let recents = try album("Recents", in: app)
        XCTAssertEqual(recents.photoCount, 36)
        await app.openAlbum(recents)
        let session = try XCTUnwrap(app.activeSession)
        session.sortNext((0..<10).map { $0 % 5 == 1 ? .delete : .keep })
        let limited = session.state

        library.access = .authorized
        await app.refreshAccess()

        XCTAssertEqual(app.path, [.sorting(albumID: recents.id)])
        XCTAssertEqual(session.state.total, 454)
        XCTAssertEqual(session.state.history, limited.history)
        XCTAssertEqual(session.state.markedIDs, limited.markedIDs)
        XCTAssertEqual(session.state.currentAssetID, limited.currentAssetID)
        XCTAssertEqual(session.state.assetIDs, library.photoIDs(inAlbum: recents.id), "in album order")
        XCTAssertEqual(app.albums.count, 6, "the user albums are listed again")
    }
}
