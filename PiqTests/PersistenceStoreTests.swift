import SwiftData
import XCTest
@testable import Piq

/// Sessions in an on-disk store across a "relaunch" (a second app model over the same store
/// file), with nothing saved on the way out, as when Piq is killed rather than quit.
@MainActor
final class PersistenceStoreTests: XCTestCase {
    /// A store file of this test's own (XCTest makes a test case object per test).
    private nonisolated let storeURL = URL.temporaryDirectory.appending(path: "PiqPersistence-\(UUID().uuidString).store")

    override func tearDown() {
        let folder = storeURL.deletingLastPathComponent()
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: folder.appending(path: storeURL.lastPathComponent + suffix))
        }
    }

    /// Killed mid-session: no trip through the background, no `saveNow()`. The next launch
    /// offers to resume at the same photo, with the same trash and undo history.
    func testAKilledSessionResumesExactly() async throws {
        var progress = SortingState(assetIDs: [])
        do {
            let app = try await launch(MockPhotoLibrary())
            let iceland = try album("Iceland 2026", in: app)
            app.selectedAlbumID = iceland.id
            await app.openAlbum(iceland)
            let session = try XCTUnwrap(app.activeSession)
            session.sortNext([.delete, .keep, .keep, .delete, .keep, .delete])
            progress = session.state
        }

        let app = try await launch(MockPhotoLibrary())
        let iceland = try album("Iceland 2026", in: app)
        XCTAssertEqual(app.selectedAlbumID, iceland.id)
        XCTAssertEqual(app.resumePoint(for: iceland.id), ResumePoint(position: 7, total: 400, markedCount: 3, isComplete: false))
        await app.openAlbum(iceland)
        let session = try XCTUnwrap(app.activeSession)
        XCTAssertEqual(session.state, progress)
        XCTAssertEqual(session.state.markedInOrder, ["mock-asset-0000", "mock-asset-0003", "mock-asset-0005"])

        XCTAssertEqual(session.undo(), SortDecision(assetID: "mock-asset-0005", action: .delete), "Undo reverses the last decision before the kill")
        XCTAssertEqual(session.state.position, 6)
        XCTAssertEqual(session.state.markedCount, 2)
    }

    /// Photos deleted the trash as the person confirmed, but Piq was killed before it heard back,
    /// so the session on disk still has those photos in its trash. The next launch finds them
    /// gone from the album and drops them.
    func testADeletionPhotosFinishedAsPiqWasKilledIsPickedUpOnTheNextLaunch() async throws {
        let trip = AlbumSummary(id: "trip", title: "Trip", kind: .user, photoCount: 6, coverAssetID: "p6")
        let library = StubPhotoLibrary()
        library.albums = [trip]
        library.albumContents = [trip.id: ["p1", "p2", "p3", "p4", "p5", "p6"]]
        let prompt = Gate()
        library.deletionGate = prompt
        let app = try await launch(library)
        await app.openAlbum(trip)
        let session = try XCTUnwrap(app.activeSession)
        session.sortNext([.delete, .keep, .delete])
        let emptying = Task { await session.emptyTrash() }
        await pollUntil("the system prompt is up") { prompt.isHolding }
        library.albumContents[trip.id] = ["p2", "p4", "p5", "p6"]

        XCTAssertEqual(try savedSessions(in: app.container).first?.state.markedInOrder, ["p1", "p3"], "nothing is saved as deleted before Photos says so")

        let relaunchedLibrary = StubPhotoLibrary()
        relaunchedLibrary.albums = [AlbumSummary(id: trip.id, title: "Trip", kind: .user, photoCount: 4, coverAssetID: "p6")]
        relaunchedLibrary.albumContents = [trip.id: ["p2", "p4", "p5", "p6"]]
        let relaunched = try await launch(relaunchedLibrary)
        XCTAssertEqual(relaunched.resumePoint(for: trip.id), ResumePoint(position: 2, total: 4, markedCount: 0, isComplete: false))
        let saved = try XCTUnwrap(relaunched.store.session(albumID: trip.id))
        XCTAssertEqual(saved.state.history, [SortDecision(assetID: "p2", action: .keep)])

        // Let the first launch's prompt go, without effect.
        library.deletionResult = .failure(.cancelled)
        prompt.open()
        _ = await emptying.value
    }

    /// The root cause of the SwiftData trap seen once while emptying the trash
    /// (`ReviewLayoutSnapshotTests.testEmptying`): the app model owned the only reference to the
    /// container, a session controller outlived it (a deletion still waiting on Photos), and when
    /// Photos answered, the controller touched a record whose container was gone. The session
    /// store now keeps the container alive for as long as a controller needs it.
    func testASessionOutlivingItsAppModelStillWorks() async throws {
        weak var appModel: AppModel?
        let session: SessionController
        do {
            let (app, scenarioSession) = PreviewSupport.session(.review)
            appModel = app
            session = scenarioSession
        }
        XCTAssertNil(appModel, "the app model is gone")

        let outcome = await session.emptyTrash()

        XCTAssertEqual(outcome, .deleted(count: 50, undeletable: 0))
        XCTAssertEqual(session.record.photoCount, 350)
        XCTAssertTrue(session.record.state.markedIDs.isEmpty)
        let container = try XCTUnwrap(session.record.modelContext?.container)
        XCTAssertEqual(try savedSessions(in: container).first?.state, session.state)
    }

    // MARK: Which album is selected on launch

    /// The picker selects the unfinished album the person sorted last. A library change touching
    /// another session (a new photo in Recents, one deleted from it) while Piq was closed must not
    /// make that one look more recent.
    func testALibraryChangeWhilePiqWasClosedKeepsTheAlbumSortedLastSelected() async throws {
        do {
            let app = try await launch(tripAndRecentsLibrary(recents: 10))
            try await sort(recents, then: trip, in: app)
        }
        // Control: the same library.
        do {
            let app = try await launch(tripAndRecentsLibrary(recents: 10))
            XCTAssertEqual(app.selectedAlbumID, trip.id)
        }

        // A screenshot lands in Recents and an old photo is deleted from it.
        let changed = tripAndRecentsLibrary(recents: 11)
        changed.albumContents[recents.id]?.removeFirst()
        let app = try await launch(changed)

        XCTAssertEqual(app.selectedAlbumID, trip.id, "Trip was sorted last")
        XCTAssertEqual(app.resumePoint(for: recents.id), ResumePoint(position: 2, total: 10, markedCount: 1, isComplete: false), "Recents did follow the library")
    }

    /// The same when the change arrives while Piq is open on the picker, and is saved then.
    func testALibraryChangeWhilePiqIsOpenKeepsTheAlbumSortedLastSelectedOnTheNextLaunch() async throws {
        do {
            let library = tripAndRecentsLibrary(recents: 10)
            let app = try await launch(library)
            try await sort(recents, then: trip, in: app)
            library.albumContents[recents.id]?.append("r11")
            library.albums = [AlbumSummary(id: recents.id, title: "Recents", kind: .recents, photoCount: 11, coverAssetID: "r11"), trip]
            await app.reloadAlbums()
            XCTAssertEqual(app.selectedAlbumID, trip.id)
            XCTAssertEqual(try savedSessions(in: app.container).first { $0.albumID == recents.id }?.state.total, 11, "the change is saved")
        }

        let app = try await launch(tripAndRecentsLibrary(recents: 11))

        XCTAssertEqual(app.selectedAlbumID, trip.id, "Trip was sorted last")
    }

    // MARK: Limited access on the next launch

    /// A Recents session saved with full access (10 photos, 5 sorted, p1 and p3 in the trash),
    /// then a launch under limited access with p1 and p8 allowed: Recents lists those two only,
    /// which says nothing about the others. Every decision and the trash stay, only the queue
    /// follows what Piq can see, and with full access again every decision and the trash are as
    /// they were, with the photo the session was on (p8) still current and the rest queued after
    /// it. (Earlier builds kept [p1, p8] with p1 sorted and in the trash: the rest was lost for
    /// good.)
    func testALaunchUnderLimitedAccessLosesNothingFromASmartAlbumSession() async throws {
        let all = (1...10).map { "p\($0)" }
        var sorted = SortingState(assetIDs: [])
        do {
            let app = try await launch(recentsLibrary(access: .authorized, photos: all))
            await app.openAlbum(try XCTUnwrap(app.albums.first))
            let session = try XCTUnwrap(app.activeSession)
            session.sortNext([.delete, .keep, .delete, .keep, .keep])
            app.returnToAlbums()
            sorted = session.state
            XCTAssertEqual(sorted.markedInOrder, ["p1", "p3"])
        }

        do {
            let app = try await launch(recentsLibrary(access: .limited, photos: ["p1", "p8"]))
            let saved = try XCTUnwrap(savedSessions(in: app.container).first?.state)
            XCTAssertEqual(saved.history, sorted.history, "every decision stays, hidden photo or not")
            XCTAssertEqual(saved.markedInOrder, ["p1", "p3"], "and so does the trash")
            XCTAssertEqual(saved.assetIDs, ["p1", "p2", "p3", "p4", "p5", "p8"], "the queue is what Piq can see")
            XCTAssertEqual(app.resumePoint(for: "recents"), ResumePoint(position: 6, total: 6, markedCount: 2, isComplete: false))
            XCTAssertEqual(app.selectedAlbumID, "recents")
        }

        let app = try await launch(recentsLibrary(access: .authorized, photos: all))
        let saved = try XCTUnwrap(savedSessions(in: app.container).first?.state)
        XCTAssertEqual(saved.history, sorted.history, "every decision as it was")
        XCTAssertEqual(saved.decisions, sorted.decisions)
        XCTAssertEqual(saved.markedIDs, sorted.markedIDs, "and the trash")
        XCTAssertEqual(saved.assetIDs, ["p1", "p2", "p3", "p4", "p5", "p8", "p6", "p7", "p9", "p10"], "the photo the session is on stays put")
        XCTAssertEqual(saved.currentAssetID, "p8")
        XCTAssertEqual(app.resumePoint(for: "recents"), ResumePoint(position: 6, total: 10, markedCount: 2, isComplete: false))
    }

    // MARK: Helpers

    /// Recents holding `photos`, as Piq sees it with `access`.
    private func recentsLibrary(access: LibraryAccess, photos: [String]) -> StubPhotoLibrary {
        let library = StubPhotoLibrary()
        library.access = access
        library.albums = [AlbumSummary(id: "recents", title: "Recents", kind: .recents, photoCount: photos.count, coverAssetID: photos.last)]
        library.albumContents = ["recents": photos]
        return library
    }

    private let recents = AlbumSummary(id: "recents", title: "Recents", kind: .recents, photoCount: 10, coverAssetID: "r10")
    private let trip = AlbumSummary(id: "trip", title: "Trip", kind: .user, photoCount: 6, coverAssetID: "t6")

    /// Recents with photos r1...r`recents`, and Trip with t1...t6.
    private func tripAndRecentsLibrary(recents count: Int) -> StubPhotoLibrary {
        let library = StubPhotoLibrary()
        library.albums = [AlbumSummary(id: recents.id, title: "Recents", kind: .recents, photoCount: count, coverAssetID: "r\(count)"), trip]
        library.albumContents = [recents.id: (1...count).map { "r\($0)" }, trip.id: (1...6).map { "t\($0)" }]
        return library
    }

    /// Sorts a little of `first`, then of `second`, and goes back to the albums each time.
    private func sort(_ first: AlbumSummary, then second: AlbumSummary, in app: AppModel) async throws {
        await app.openAlbum(first)
        try XCTUnwrap(app.activeSession).sortNext([.keep, .delete])
        app.returnToAlbums()
        await app.openAlbum(second)
        try XCTUnwrap(app.activeSession).sortNext([.keep, .keep, .delete])
        app.returnToAlbums()
        XCTAssertEqual(app.selectedAlbumID, second.id)
    }

    /// An app model over `library` and the on-disk store, started like a launch.
    private func launch(_ library: any PhotoLibraryClient) async throws -> AppModel {
        let container = try SessionStore.makeContainer(ModelConfiguration(url: storeURL, cloudKitDatabase: .none))
        let app = AppModel(library: library, images: SpyImageSource(), container: container)
        await app.start()
        return app
    }
}
