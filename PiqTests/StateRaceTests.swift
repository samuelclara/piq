import SwiftData
import XCTest
@testable import Piq

/// Work that waits on Photos (opening an album, a reload, the system deletion prompt) while
/// something else changes the same session or the library underneath it.
@MainActor
final class StateRaceTests: XCTestCase {
    private let trip = AlbumSummary(id: "trip", title: "Trip", kind: .user, photoCount: 6, coverAssetID: "p6")
    private let allPhotos = ["p1", "p2", "p3", "p4", "p5", "p6"]

    /// An app over a stub library listing Trip with p1...p6, started.
    private func startedTripApp() async -> (AppModel, StubPhotoLibrary) {
        let library = StubPhotoLibrary()
        library.albums = [trip]
        library.albumContents = [trip.id: allPhotos]
        let app = AppModel(library: library, images: SpyImageSource(), container: PreviewSupport.inMemoryContainer())
        await app.start()
        return (app, library)
    }

    // MARK: Opening an album

    func testOpeningANewAlbumDoesNotBringBackAPhotoDeletedWhileItOpened() async throws {
        let (app, library) = await startedTripApp()
        // The person opens Trip and Photos is slow to answer (iCloud keeps it busy after an
        // import); a held lookup answers with what the album had when it was asked...
        let slowLookup = Gate()
        library.albumGates[trip.id] = slowLookup
        let opening = Task { await app.openAlbum(trip) }
        await pollUntil("Photos is asked for Trip's photos") { slowLookup.isHolding }
        // ...while p4 is deleted in Photos and the reload for that change runs to the end.
        library.albumContents[trip.id] = ["p1", "p2", "p3", "p5", "p6"]
        await app.reloadAlbums()

        slowLookup.open()
        await opening.value

        let session = try XCTUnwrap(app.activeSession)
        XCTAssertEqual(session.state.assetIDs, ["p1", "p2", "p3", "p5", "p6"], "a photo deleted in Photos came back")
        assertRecord(try XCTUnwrap(app.store.session(albumID: trip.id)), matches: session.state)
        XCTAssertEqual(app.path, [.sorting(albumID: trip.id)])
        XCTAssertEqual(library.answeredLookups, 2, "asked once more, after the reload")
    }

    func testResumingAnAlbumDoesNotBringBackAPhotoDeletedWhileItOpened() async throws {
        let (app, library) = await startedTripApp()
        await app.openAlbum(trip)
        let session = try XCTUnwrap(app.activeSession)
        session.sortNext([.keep, .delete])
        app.returnToAlbums()

        let slowLookup = Gate()
        library.albumGates[trip.id] = slowLookup
        let opening = Task { await app.openAlbum(trip) }
        await pollUntil("Photos is asked for Trip's photos") { slowLookup.isHolding }
        library.albumContents[trip.id] = ["p1", "p2", "p3", "p5", "p6"]
        await app.reloadAlbums()
        XCTAssertFalse(session.state.assetIDs.contains("p4"), "the reload dropped p4")

        slowLookup.open()
        await opening.value

        XCTAssertTrue(app.activeSession === session)
        XCTAssertEqual(session.state.assetIDs, ["p1", "p2", "p3", "p5", "p6"], "a photo deleted in Photos came back")
        XCTAssertEqual(session.state.markedInOrder, ["p2"])
        XCTAssertEqual(session.state.position, 3)
        assertRecord(try XCTUnwrap(app.store.session(albumID: trip.id)), matches: session.state)
        XCTAssertEqual(app.resumePoint(for: trip.id), ResumePoint(position: 3, total: 5, markedCount: 1, isComplete: false))
    }

    func testOpeningAnAlbumAsAccessGoesAwayStaysOnThePicker() async throws {
        let (app, library) = await startedTripApp()
        let slowLookup = Gate()
        library.albumGates[trip.id] = slowLookup
        let opening = Task { await app.openAlbum(trip) }
        await pollUntil("Photos is asked for Trip's photos") { slowLookup.isHolding }
        // Meanwhile the person turns off Photos access in Settings and comes back.
        library.access = .denied
        await app.refreshAccess()

        slowLookup.open()
        await opening.value

        XCTAssertEqual(app.path, [], "the picker explains how to give access again")
        XCTAssertNil(app.activeSession)
        XCTAssertFalse(app.isOpeningAlbum)
        XCTAssertNil(app.toasts.current, "no word about the album: it isn't the album that's missing")
        XCTAssertTrue(try savedSessions(in: app.container).isEmpty)
    }

    func testOpeningAgainWhileAnAlbumOpensDoesNothing() async throws {
        let (app, library) = await startedTripApp()
        let slowLookup = Gate()
        library.albumGates[trip.id] = slowLookup
        let opening = Task { await app.openAlbum(trip) }
        await pollUntil("Photos is asked for Trip's photos") { slowLookup.isHolding }

        await app.openAlbum(trip)
        XCTAssertTrue(app.isOpeningAlbum)
        XCTAssertEqual(app.path, [])

        slowLookup.open()
        await opening.value
        XCTAssertEqual(app.path, [.sorting(albumID: trip.id)])
        XCTAssertEqual(library.answeredLookups, 1)
        XCTAssertEqual(try savedSessions(in: app.container).count, 1)
    }

    // MARK: One controller per session

    func testReopeningAnAlbumResumesTheSameSessionObject() async throws {
        let (app, _) = try await startedApp()
        let lisbon = try album("Weekend in Lisbon", in: app)
        await app.openAlbum(lisbon)
        let first = try XCTUnwrap(app.activeSession)
        first.sortNext([.keep, .delete])
        app.returnToAlbums()
        let family = try album("Family", in: app)
        await app.openAlbum(family)
        app.returnToAlbums()

        await app.openAlbum(lisbon)

        XCTAssertTrue(app.activeSession === first, "a second controller would hold a second copy of the session")
    }

    /// A finished session with an empty trash starts over when opened again: in place, so anything
    /// still holding its controller sees the fresh start rather than writing back the old session.
    func testASessionThatStartsOverDoesSoInPlace() async throws {
        let (app, _) = try await startedApp()
        let family = try album("Family", in: app)
        await app.openAlbum(family)
        let session = try XCTUnwrap(app.activeSession)
        session.sortNext(Array(repeating: .keep, count: 18))
        app.returnToAlbums()

        await app.openAlbum(family)

        XCTAssertTrue(app.activeSession === session)
        XCTAssertEqual(session.state, SortingState(assetIDs: session.state.assetIDs))
        XCTAssertEqual(session.state.total, 18)
        XCTAssertNil(session.lastChange)
        assertRecord(session.record, matches: session.state)
        XCTAssertEqual(try savedSessions(in: app.container).map(\.state), [session.state])
    }

    /// The trash is being emptied (the system prompt is up) when Piq goes back to the albums
    /// (access switched off and on again in Settings, say) and the person opens the album again
    /// and sorts on. The deletion lands on the session as it is by then: nothing sorted since is
    /// lost, and nothing deleted comes back.
    func testADeletionLandingAfterTheAlbumWasReopenedKeepsWhatWasSortedSince() async throws {
        let (app, library) = await startedTripApp()
        await app.openAlbum(trip)
        let session = try XCTUnwrap(app.activeSession)
        session.sortNext([.delete, .keep, .delete])
        app.showReview()
        let prompt = Gate()
        library.deletionGate = prompt
        library.deletionResult = .success(DeletionReport(deleted: ["p1", "p3"], missing: [], undeletable: []))
        let emptying = Task { await session.emptyTrash() }
        await pollUntil("the system prompt is up") { prompt.isHolding }

        app.returnToAlbums()
        await app.openAlbum(trip)
        let reopened = try XCTUnwrap(app.activeSession)
        reopened.sortNext([.keep])
        // Photos deletes p1 and p3 as the person confirms.
        library.albumContents[trip.id] = ["p2", "p4", "p5", "p6"]
        prompt.open()
        let outcome = await emptying.value
        await app.reloadAlbums()

        XCTAssertEqual(outcome, .deleted(count: 2, undeletable: 0))
        XCTAssertTrue(reopened === session)
        XCTAssertEqual(session.state.history, [SortDecision(assetID: "p2", action: .keep), SortDecision(assetID: "p4", action: .keep)])
        XCTAssertEqual(session.state.assetIDs, ["p2", "p4", "p5", "p6"])
        XCTAssertTrue(session.state.markedIDs.isEmpty)
        assertRecord(session.record, matches: session.state)
        XCTAssertEqual(try savedSessions(in: app.container).first?.state, session.state)
    }

    // MARK: Emptying the trash while the library changes

    /// A reload asked Photos for the album before the trash was emptied and gets its answer after:
    /// that answer still lists the deleted photos, and must not put them back in the queue.
    func testAReloadThatAskedBeforeTheTrashWasEmptiedDoesNotBringThePhotosBack() async throws {
        let (app, library) = await startedTripApp()
        await app.openAlbum(trip)
        let session = try XCTUnwrap(app.activeSession)
        session.sortNext([.delete, .keep, .delete, .keep, .keep, .keep])
        XCTAssertTrue(session.state.isComplete)
        app.showReview()

        let slowLookup = Gate()
        library.albumGates[trip.id] = slowLookup
        let olderReload = Task { await app.reloadAlbums() }
        await pollUntil("the reload waits on Photos") { slowLookup.isHolding }
        library.deletionResult = .success(DeletionReport(deleted: ["p1", "p3"], missing: [], undeletable: []))
        library.albumContents[trip.id] = ["p2", "p4", "p5", "p6"]
        let outcome = await session.emptyTrash()
        XCTAssertEqual(outcome, .deleted(count: 2, undeletable: 0))

        slowLookup.open()
        await olderReload.value
        // Emptying the trash started a fresh reload too; let it finish (one lookup to open Trip,
        // one each for the two reloads).
        await pollUntil("the fresh reload has asked Photos") { library.answeredLookups == 3 }
        await pollUntil("the fresh reload is done") { !app.isLoadingAlbums }

        XCTAssertEqual(session.state.assetIDs, ["p2", "p4", "p5", "p6"], "deleted photos came back")
        XCTAssertTrue(session.state.isComplete)
        XCTAssertTrue(session.state.markedIDs.isEmpty)
        XCTAssertEqual(app.path, [.sorting(albumID: trip.id), .review(albumID: trip.id)])
        assertRecord(session.record, matches: session.state)
    }

    /// While the system prompt is up, a photo in the trash is deleted elsewhere and a new one is
    /// added; the reload for that runs (and saves) before Photos answers the deletion.
    func testALibraryChangeWhileTheSystemPromptIsUpIsKept() async throws {
        let (app, library) = await startedTripApp()
        await app.openAlbum(trip)
        let session = try XCTUnwrap(app.activeSession)
        session.sortNext([.delete, .keep, .delete, .keep])
        let prompt = Gate()
        library.deletionGate = prompt
        library.deletionResult = .success(DeletionReport(deleted: ["p1"], missing: ["p3"], undeletable: []))
        let emptying = Task { await session.emptyTrash() }
        await pollUntil("the system prompt is up") { prompt.isHolding }

        library.albumContents[trip.id] = ["p1", "p2", "p4", "p5", "p6", "p7"]
        await app.reloadAlbums()
        XCTAssertEqual(session.state.markedInOrder, ["p1"], "p3 left the trash")
        XCTAssertEqual(session.state.assetIDs.last, "p7", "the new photo is queued")
        XCTAssertEqual(try savedSessions(in: app.container).first?.state, session.state, "saved while the prompt is still up")

        library.albumContents[trip.id] = ["p2", "p4", "p5", "p6", "p7"]
        prompt.open()
        let outcome = await emptying.value

        XCTAssertEqual(outcome, .deleted(count: 1, undeletable: 0))
        XCTAssertEqual(session.state.assetIDs, ["p2", "p4", "p5", "p6", "p7"])
        XCTAssertEqual(session.state.history.map(\.assetID), ["p2", "p4"])
        XCTAssertEqual(session.state.currentAssetID, "p5")
        XCTAssertTrue(session.state.markedIDs.isEmpty)
        XCTAssertEqual(try savedSessions(in: app.container).first?.state, session.state)
    }

    // MARK: Navigation

    /// The sorting screen commits a card still in the air as it closes. If that was the last
    /// photo, the deck asks for Review, which must not reopen a screen the app just left.
    func testTheLastDecisionLandingAsTheScreenClosesDoesNotOpenReview() async throws {
        let (app, _) = try await startedApp()
        let family = try album("Family", in: app)
        await app.openAlbum(family)
        let session = try XCTUnwrap(app.activeSession)
        session.sortNext(Array(repeating: .keep, count: 17))

        app.returnToAlbums()
        session.decide(.keep)
        XCTAssertTrue(session.state.isComplete)
        app.showReview()

        XCTAssertEqual(app.path, [])
    }
}
