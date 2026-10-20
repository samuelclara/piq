import XCTest
@testable import Piq

/// Photos deleted outside Piq: the library reports a change, the app reloads (debounced) and
/// every saved session drops what is gone.
@MainActor
final class LibraryChangeTests: XCTestCase {
    func testAPhotoDeletedOutsidePiqLeavesTheOpenSessionAndItsTrash() async throws {
        let (app, library) = try await startedApp()
        let lisbon = try album("Weekend in Lisbon", in: app)
        await app.openAlbum(lisbon)
        let session = try XCTUnwrap(app.activeSession)
        let ids = session.state.assetIDs
        session.sortNext([.keep, .delete, .keep, .delete, .keep])

        library.remove([ids[1]])

        await pollUntil("the open session drops the deleted photo") { !session.state.assetIDs.contains(ids[1]) }
        XCTAssertFalse(session.state.history.contains { $0.assetID == ids[1] }, "gone from the undo history")
        XCTAssertEqual(session.state.markedInOrder, [ids[3]], "gone from the trash")
        XCTAssertEqual(session.state.currentAssetID, ids[5], "the photo on screen doesn't change")
        XCTAssertEqual(session.state.position, 5)
        XCTAssertEqual(session.state.total, 35)
        XCTAssertEqual(session.lastChange, .reconciled)
        XCTAssertTrue(app.activeSession === session, "the open session is updated in place")
        let record = try XCTUnwrap(app.store.session(albumID: lisbon.id))
        assertRecord(record, matches: session.state)
        XCTAssertEqual(app.resumePoint(for: lisbon.id), ResumePoint(position: 5, total: 35, markedCount: 1, isComplete: false))
        XCTAssertEqual(app.albums.first { $0.id == lisbon.id }?.photoCount, 35)
        await pollUntil("the change is saved") {
            (try? savedSessions(in: app.container))?.first?.state == session.state
        }
    }

    func testWhenThePhotoOnScreenIsDeletedTheNextOneTakesItsPlace() async throws {
        let (app, library) = try await startedApp()
        let lisbon = try album("Weekend in Lisbon", in: app)
        await app.openAlbum(lisbon)
        let session = try XCTUnwrap(app.activeSession)
        let ids = session.state.assetIDs
        session.sortNext([.keep, .keep])

        library.remove([ids[2]])

        await pollUntil("the next photo moves up") { session.state.currentAssetID == ids[3] }
        XCTAssertEqual(session.state.position, 3)
        XCTAssertEqual(session.state.total, 35)
        // A swipe that was under way for the deleted photo must not land on its neighbour.
        XCTAssertNil(session.decide(.delete, for: ids[2]))
        XCTAssertEqual(session.state.currentAssetID, ids[3])
        XCTAssertTrue(session.state.markedIDs.isEmpty)
    }

    func testSavedSessionsThatAreNotOpenAreReconciledToo() async throws {
        let (app, library) = try await startedApp()
        let family = try album("Family", in: app)
        let lisbon = try album("Weekend in Lisbon", in: app)
        await app.openAlbum(family)
        let familySession = try XCTUnwrap(app.activeSession)
        let ids = familySession.state.assetIDs
        familySession.sortNext([.delete, .keep, .delete, .keep])
        app.returnToAlbums()
        await app.openAlbum(lisbon)
        XCTAssertEqual(app.activeSession?.albumID, lisbon.id)

        // A sorted photo in Family's trash, and one Family hasn't reached yet.
        library.remove([ids[0], ids[10]])

        let record = try XCTUnwrap(app.store.session(albumID: family.id))
        await pollUntil("the Family session drops the deleted photos") { !record.state.assetIDs.contains(ids[0]) }
        var expected = familySession.state
        expected.remove([ids[0], ids[10]])
        assertRecord(record, matches: expected)
        XCTAssertEqual(record.state.markedInOrder, [ids[2]])
        XCTAssertEqual(record.state.currentIndex, 3)
        XCTAssertEqual(app.resumePoint(for: family.id), ResumePoint(position: 4, total: 16, markedCount: 1, isComplete: false))
        XCTAssertNotEqual(app.activeSession?.lastChange, .reconciled, "nothing changed in the open Lisbon session")
        await pollUntil("the change is saved") {
            (try? savedSessions(in: app.container))?.first { $0.albumID == family.id }?.state == expected
        }
    }

    func testLimitedAccessLeavesSessionsOfHiddenAlbumsAlone() async throws {
        // A session saved while Piq had full access...
        let icelandID = MockPhotoLibrary.icelandAlbumID
        let icelandIDs = MockPhotoLibrary().photoIDs(inAlbum: icelandID)
        var progress = SortingState(assetIDs: icelandIDs)
        for index in 0..<37 { progress.apply(index % 8 == 3 ? .delete : .keep) }
        // ...and Piq launched again after the person switched to limited access, which hides
        // user albums without deleting them.
        let app = PreviewSupport.appModel(nil, access: .limited)
        let library = try mockLibrary(of: app)
        let record = app.store.insertSession(albumID: icelandID, title: "Iceland 2026", assetIDs: icelandIDs)
        record.state = progress
        app.store.save()

        await app.start()

        XCTAssertFalse(app.albums.contains { $0.id == icelandID })
        assertRecord(record, matches: progress)
        XCTAssertEqual(app.resumePoint(for: icelandID), ResumePoint(position: 38, total: 400, markedCount: 5, isComplete: false))

        // Nor does a later change to the photos Piq can see.
        let recents = try album("Recents", in: app)
        let removed = try XCTUnwrap(library.photoIDs(inAlbum: recents.id).last)
        library.remove([removed])
        await pollUntil("the album list catches up") { app.albums.first?.photoCount == 35 }
        assertRecord(record, matches: progress)
        XCTAssertEqual(try savedSessions(in: app.container).map(\.state), [progress])
    }

    func testAnAlbumThatIsNotListedIsLeftAloneEvenIfPhotosStillAnswersForIt() async {
        // Photos lists only Recents but still answers for the trip album, with none of its photos
        // visible. That means hidden, not emptied, so the session must survive.
        let library = StubPhotoLibrary()
        library.access = .limited
        library.albums = [AlbumSummary(id: "recents", title: "Recents", kind: .recents, photoCount: 2, coverAssetID: "p2")]
        library.albumContents = ["recents": ["p1", "p2"], "trip": []]
        let app = AppModel(library: library, images: SpyImageSource(), container: PreviewSupport.inMemoryContainer())
        let tripIDs = (1...6).map { "trip-\($0)" }
        var progress = SortingState(assetIDs: tripIDs)
        progress.apply(.delete)
        progress.apply(.keep)
        let record = app.store.insertSession(albumID: "trip", title: "Trip", assetIDs: tripIDs)
        record.state = progress

        await app.start()

        assertRecord(record, matches: progress)
        XCTAssertEqual(app.resumePoint(for: "trip"), ResumePoint(position: 3, total: 6, markedCount: 1, isComplete: false))
    }

    func testAnAlbumOpenedDuringAReloadKeepsItsResumePoint() async throws {
        let library = StubPhotoLibrary()
        let trip = AlbumSummary(id: "trip", title: "Trip", kind: .user, photoCount: 4, coverAssetID: "t4")
        let family = AlbumSummary(id: "family", title: "Family", kind: .user, photoCount: 4, coverAssetID: "f4")
        library.albums = [trip, family]
        library.albumContents = [trip.id: ["t1", "t2", "t3", "t4"], family.id: ["f1", "f2", "f3", "f4"]]
        let app = AppModel(library: library, images: SpyImageSource(), container: PreviewSupport.inMemoryContainer())
        await app.start()
        await app.openAlbum(trip)
        try XCTUnwrap(app.activeSession).sortNext([.keep])
        app.returnToAlbums()

        // A library change starts a reload, which waits on Photos while it checks the Trip
        // session (iCloud keeps Photos busy right after an import)...
        let slowFetch = Gate()
        library.albumGates[trip.id] = slowFetch
        let reload = Task { await app.reloadAlbums() }
        await pollUntil("the reload waits on Photos") { slowFetch.isHolding }
        // ...and meanwhile the person opens Family, sorts a photo and goes back.
        await app.openAlbum(family)
        try XCTUnwrap(app.activeSession).sortNext([.delete])
        app.returnToAlbums()
        slowFetch.open()
        await reload.value

        XCTAssertNotNil(app.store.session(albumID: family.id), "the Family session is saved")
        XCTAssertEqual(
            app.resumePoint(for: family.id),
            ResumePoint(position: 2, total: 4, markedCount: 1, isComplete: false),
            "the picker must offer Resume · 2 of 4, not Start sorting"
        )
        XCTAssertEqual(app.resumePoint(for: trip.id), ResumePoint(position: 2, total: 4, markedCount: 0, isComplete: false))
    }

    // MARK: Overlapping reloads

    // PhotoKit answers every fetch from a detached task, so during an iCloud import burst an older
    // reload can get its answer after a newer one. Only the newest reload may apply its answers.

    func testASupersededReloadDoesNotBringBackADeletedPhoto() async throws {
        let library = StubPhotoLibrary()
        let trip = AlbumSummary(id: "trip", title: "Trip", kind: .user, photoCount: 6, coverAssetID: "p6")
        library.albums = [trip]
        library.albumContents = [trip.id: ["p1", "p2", "p3", "p4", "p5", "p6"]]
        let app = AppModel(library: library, images: SpyImageSource(), container: PreviewSupport.inMemoryContainer())
        await app.start()
        await app.openAlbum(trip)
        let session = try XCTUnwrap(app.activeSession)
        session.sortNext([.keep, .delete])

        // A library change starts a reload, which asks Photos for Trip's photos and waits...
        let slowLookup = Gate()
        library.albumGates[trip.id] = slowLookup
        library.onChange?()
        await pollUntil("the first reload waits on Photos") { slowLookup.isHolding }
        // ...while p4 is deleted in Photos and the reload for that change drops it.
        library.albumContents[trip.id] = ["p1", "p2", "p3", "p5", "p6"]
        library.onChange?()
        await pollUntil("the second reload drops p4") { !session.state.assetIDs.contains("p4") }

        // The first reload gets its answer from before the deletion. The code after an answer
        // runs before the main actor is free again, so once all three lookups (opening Trip and
        // the two reloads) have answered, the first reload has done all it will do with it.
        slowLookup.open()
        await pollUntil("the first reload gets its answer") { library.answeredLookups == 3 }

        XCTAssertEqual(session.state.assetIDs, ["p1", "p2", "p3", "p5", "p6"], "a photo deleted in Photos came back")
        XCTAssertEqual(session.state.markedInOrder, ["p2"])
        assertRecord(try XCTUnwrap(app.store.session(albumID: trip.id)), matches: session.state)
        XCTAssertEqual(app.resumePoint(for: trip.id), ResumePoint(position: 3, total: 5, markedCount: 1, isComplete: false))
    }

    func testASupersededReloadDoesNotBringBackADeletedAlbum() async {
        let library = StubPhotoLibrary()
        let trip = AlbumSummary(id: "trip", title: "Trip", kind: .user, photoCount: 2, coverAssetID: "t2")
        let party = AlbumSummary(id: "party", title: "Party", kind: .user, photoCount: 2, coverAssetID: "p2")
        library.albums = [trip, party]
        library.albumContents = [trip.id: ["t1", "t2"], party.id: ["p1", "p2"]]
        let app = AppModel(library: library, images: SpyImageSource(), container: PreviewSupport.inMemoryContainer())
        await app.start()

        // A reload asks Photos for the album list and waits...
        let slowListing = Gate()
        library.albumListGate = slowListing
        let olderReload = Task { await app.reloadAlbums() }
        await pollUntil("the older reload waits on Photos") { slowListing.isHolding }
        // ...while Party is deleted in Photos and a newer reload lists what is left.
        library.albums = [trip]
        library.albumContents[party.id] = nil
        await app.reloadAlbums()
        XCTAssertEqual(app.albums.map(\.id), [trip.id])

        slowListing.open()
        await olderReload.value

        XCTAssertEqual(app.albums.map(\.id), [trip.id], "the deleted album came back")
        XCTAssertFalse(app.isLoadingAlbums)
    }

    func testASupersededReloadKeepsTheSelectionOfANewAlbum() async throws {
        let library = StubPhotoLibrary()
        let trip = AlbumSummary(id: "trip", title: "Trip", kind: .user, photoCount: 3, coverAssetID: "t3")
        library.albums = [trip]
        library.albumContents = [trip.id: ["t1", "t2", "t3"]]
        let app = AppModel(library: library, images: SpyImageSource(), container: PreviewSupport.inMemoryContainer())
        await app.start()
        await app.openAlbum(trip)
        try XCTUnwrap(app.activeSession).sortNext([.keep])
        app.returnToAlbums()

        // A reload lists the albums, then waits on Photos while it checks the Trip session...
        let slowLookup = Gate()
        library.albumGates[trip.id] = slowLookup
        let olderReload = Task { await app.reloadAlbums() }
        await pollUntil("the older reload waits on Photos") { slowLookup.isHolding }
        // ...while an album is created in Photos, a newer reload lists it and the person selects it.
        let party = AlbumSummary(id: "party", title: "Party", kind: .user, photoCount: 2, coverAssetID: "p2")
        library.albums = [trip, party]
        library.albumContents[party.id] = ["p1", "p2"]
        await app.reloadAlbums()
        app.selectedAlbumID = party.id

        slowLookup.open()
        await olderReload.value

        XCTAssertEqual(app.selectedAlbumID, party.id, "the older reload never listed Party, so it must not undo the selection")
        XCTAssertEqual(app.albums.map(\.id), [trip.id, party.id])
    }

    func testLosingAccessWhileAReloadWaitsListsNoAlbums() async {
        let library = StubPhotoLibrary()
        library.albums = [AlbumSummary(id: "trip", title: "Trip", kind: .user, photoCount: 2, coverAssetID: "t2")]
        library.albumContents = ["trip": ["t1", "t2"]]
        let app = AppModel(library: library, images: SpyImageSource(), container: PreviewSupport.inMemoryContainer())
        await app.start()

        let slowListing = Gate()
        library.albumListGate = slowListing
        let olderReload = Task { await app.reloadAlbums() }
        await pollUntil("the reload waits on Photos") { slowListing.isHolding }
        XCTAssertTrue(app.isLoadingAlbums)
        // Meanwhile the person turns off Photos access in Settings and comes back to Piq.
        library.access = .denied
        await app.refreshAccess()

        slowListing.open()
        await olderReload.value

        XCTAssertEqual(app.access, .denied)
        XCTAssertTrue(app.albums.isEmpty, "albums listed without access")
        XCTAssertFalse(app.isLoadingAlbums, "nothing is loading without access")
    }
}
