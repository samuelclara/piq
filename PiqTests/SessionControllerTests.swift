import XCTest
@testable import Piq

@MainActor
final class SessionControllerTests: XCTestCase {
    // MARK: Sorting

    func testDecideAppliesTheActionToThePhotoOnScreen() {
        let fixture = SessionFixture()
        let session = fixture.session
        let ids = fixture.ids
        XCTAssertNil(session.lastChange)

        XCTAssertEqual(session.decide(.keep), SortDecision(assetID: ids[0], action: .keep))
        XCTAssertEqual(session.lastChange, .decided(SortDecision(assetID: ids[0], action: .keep)))

        XCTAssertEqual(session.decide(.delete), SortDecision(assetID: ids[1], action: .delete))
        XCTAssertEqual(session.lastChange, .decided(SortDecision(assetID: ids[1], action: .delete)))
        XCTAssertEqual(session.state.currentAssetID, ids[2])
        XCTAssertEqual(session.state.position, 3)
        XCTAssertEqual(session.state.markedInOrder, [ids[1]])
        XCTAssertTrue(session.state.canUndo)
        XCTAssertEqual(fixture.library.photoIDs(inAlbum: session.albumID), ids, "marking deletes nothing from Photos")
    }

    func testDecideRefusesAPhotoThatIsNoLongerOnScreen() {
        let fixture = SessionFixture()
        let session = fixture.session
        let ids = fixture.ids
        XCTAssertEqual(session.decide(.keep, for: ids[0]), SortDecision(assetID: ids[0], action: .keep))
        let before = session.state

        XCTAssertNil(session.decide(.delete, for: ids[0]), "a second action for the photo that was just sorted")
        XCTAssertNil(session.decide(.delete, for: ids[2]), "a photo further down the queue")
        XCTAssertNil(session.decide(.keep, for: "photo-from-another-album"))

        XCTAssertEqual(session.state, before)
        XCTAssertEqual(session.lastChange, .decided(SortDecision(assetID: ids[0], action: .keep)))
        assertRecord(fixture.record, matches: before)

        XCTAssertEqual(session.decide(.delete, for: ids[1]), SortDecision(assetID: ids[1], action: .delete))
    }

    func testDecideDoesNothingOnceEveryPhotoIsSorted() {
        let fixture = SessionFixture()
        let session = fixture.session
        session.sortNext(Array(repeating: .keep, count: fixture.ids.count))
        XCTAssertTrue(session.state.isComplete)
        let lastChange = session.lastChange

        XCTAssertNil(session.decide(.delete))
        XCTAssertEqual(session.lastChange, lastChange)
        XCTAssertEqual(session.state.sortedCount, fixture.ids.count)
        XCTAssertTrue(session.state.markedIDs.isEmpty)
    }

    func testUndoGoesBackAndReversesTheDecision() {
        let fixture = SessionFixture()
        let session = fixture.session
        let ids = fixture.ids
        XCTAssertNil(session.undo(), "nothing to undo yet")
        XCTAssertNil(session.lastChange)

        session.sortNext([.keep, .delete])
        XCTAssertEqual(session.undo(), SortDecision(assetID: ids[1], action: .delete))
        XCTAssertEqual(session.lastChange, .undone(SortDecision(assetID: ids[1], action: .delete)))
        XCTAssertEqual(session.state.currentAssetID, ids[1])
        XCTAssertTrue(session.state.markedIDs.isEmpty, "the undone photo leaves the trash")

        XCTAssertEqual(session.undo(), SortDecision(assetID: ids[0], action: .keep))
        XCTAssertNil(session.undo())
        XCTAssertEqual(session.lastChange, .undone(SortDecision(assetID: ids[0], action: .keep)), "a refused undo isn't a change")
        XCTAssertEqual(session.state.currentAssetID, ids[0])
        XCTAssertFalse(session.state.canUndo)
    }

    // MARK: Restoring

    func testRestoreTakesPhotosOffTheTrashAndCountsThemAsKept() {
        let fixture = SessionFixture()
        let session = fixture.session
        let ids = fixture.ids
        session.sortNext([.delete, .keep, .delete, .delete, .keep])

        // ids[1] was kept and "unknown" isn't in the session, so only two photos are restored.
        session.restore([ids[0], ids[3], ids[1], "unknown"])

        XCTAssertEqual(session.lastChange, .restored(count: 2))
        XCTAssertEqual(session.state.markedInOrder, [ids[2]])
        XCTAssertEqual(session.state.sortedCount, 5, "restored photos stay sorted")
        XCTAssertEqual(session.state.keptCount, 4)
        XCTAssertEqual(session.state.currentAssetID, ids[5])
    }

    func testRestoringPhotosThatAreNotMarkedChangesNothing() {
        let fixture = SessionFixture()
        let session = fixture.session
        session.sortNext([.keep, .delete])
        let before = session.state
        let updatedAt = fixture.record.updatedAt

        session.restore([fixture.ids[0], fixture.ids[5]])
        session.restore([])

        XCTAssertEqual(session.state, before)
        XCTAssertEqual(session.lastChange, .decided(SortDecision(assetID: fixture.ids[1], action: .delete)))
        XCTAssertEqual(fixture.record.updatedAt, updatedAt, "the record isn't touched")
    }

    // MARK: Persistence

    func testEveryChangeIsWrittenThroughToTheRecord() {
        let fixture = SessionFixture()
        let session = fixture.session
        let record = fixture.record
        let ids = fixture.ids
        assertRecord(record, matches: session.state)

        // Marks spread across the album, so the stored trash can't match session order by luck.
        for action in [SwipeAction.delete, .keep, .delete, .keep, .keep, .delete, .delete, .keep, .delete] {
            session.decide(action)
            assertRecord(record, matches: session.state)
        }
        XCTAssertEqual(record.state.markedInOrder, [ids[0], ids[2], ids[5], ids[6], ids[8]])

        session.undo()
        assertRecord(record, matches: session.state)
        session.decide(.keep)
        assertRecord(record, matches: session.state)
        session.restore([ids[2], ids[6]])
        assertRecord(record, matches: session.state)
        XCTAssertEqual(record.state.markedInOrder, [ids[0], ids[5]])
        XCTAssertEqual(record.state.currentIndex, 9)
    }

    /// The picker selects the session the person worked on last, so only their changes count
    /// (`updatedAt`): a library change or a rename in Photos doesn't make a session more recent.
    func testOnlyThePersonsChangesMakeTheSessionTheOneWorkedOnLast() async throws {
        let fixture = SessionFixture()
        let session = fixture.session
        let record = fixture.record
        let ids = fixture.ids
        session.sortNext([.delete, .keep])
        var last = record.updatedAt
        func expectTouched(_ touched: Bool, _ change: String, line: UInt = #line) async throws {
            if touched {
                XCTAssertGreaterThan(record.updatedAt, last, change, line: line)
            } else {
                XCTAssertEqual(record.updatedAt, last, change, line: line)
            }
            XCTAssertEqual(try savedSessions(in: fixture.container).first?.state, session.state, "\(change) is saved", line: line)
            last = record.updatedAt
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(5))

        session.reconcile(withAlbumAssetIDs: ids + ["new-photo"])
        try await expectTouched(false, "a photo added in Photos")
        session.reconcile(withAlbumAssetIDs: ids.filter { $0 != ids[1] })
        try await expectTouched(false, "a photo deleted in Photos")
        session.rename("Lisbon, May 2026")
        try await expectTouched(false, "the album renamed in Photos")

        session.decide(.keep)
        try await expectTouched(true, "a decision")
        session.undo()
        try await expectTouched(true, "an undo")
        session.restore([ids[0]])
        try await expectTouched(true, "a restore")
        session.decide(.delete)
        _ = await session.emptyTrash()
        try await expectTouched(true, "emptying the trash")
        session.markOpened()
        try await expectTouched(true, "opening the album")
    }

    /// A record holding more decisions than photos (written by an earlier build, or damaged) opens
    /// as a finished session. From its first change on, what is saved is what the session shows:
    /// an undo, a decision and a photo queued later all line up with the photo list.
    func testASessionWithMoreDecisionsThanPhotosIsSavedExactlyFromItsFirstChange() throws {
        let container = PreviewSupport.inMemoryContainer()
        let store = SessionStore(context: container.mainContext)
        let record = store.insertSession(albumID: "album", title: "Album", assetIDs: ["p1", "p2", "p3", "p4"])
        record.decisions = Data("kDkkdd".utf8)
        record.cursor = nil
        record.undoLog = nil
        store.save()
        let session = SessionController(record: record, store: store, library: StubPhotoLibrary())
        XCTAssertTrue(session.state.isComplete)

        XCTAssertEqual(session.undo(), SortDecision(assetID: "p4", action: .keep))
        assertRecord(record, matches: session.state)
        session.decide(.delete)
        assertRecord(record, matches: session.state)
        session.reconcile(withAlbumAssetIDs: ["p1", "p2", "p3", "p4", "p5"])
        assertRecord(record, matches: session.state)
        XCTAssertEqual(try savedSessions(in: container).first?.state, session.state)
        XCTAssertEqual(session.state.currentAssetID, "p5")
    }

    /// Piq can be killed right after a swipe (a crash, the system reclaiming memory) with no
    /// chance to save on the way out, so every change is on disk as soon as it is made.
    func testEveryChangeIsSavedRightAway() async throws {
        let fixture = SessionFixture()
        let session = fixture.session
        let ids = fixture.ids
        func assertSaved(_ step: String, line: UInt = #line) throws {
            XCTAssertEqual(try savedSessions(in: fixture.container).first?.state, session.state, step, line: line)
        }

        for action in [SwipeAction.keep, .delete, .keep, .delete] {
            session.decide(action)
            try assertSaved("after \(action)")
        }
        session.undo()
        try assertSaved("after undo")
        session.restore([ids[1]])
        try assertSaved("after restore")
        session.reconcile(withAlbumAssetIDs: ids.filter { $0 != ids[0] } + ["new-photo"])
        try assertSaved("after a library change")
        session.rename("Lisbon, May 2026")
        XCTAssertEqual(try savedSessions(in: fixture.container).first?.albumTitle, "Lisbon, May 2026")
        _ = await session.emptyTrash()
        try assertSaved("after emptying the trash")
    }

    // MARK: Emptying the trash

    func testEmptyTrashMovesTheMarkedPhotosOutOfPhotosAndTheSession() async throws {
        let fixture = SessionFixture(deletion: .succeed)
        let session = fixture.session
        let ids = fixture.ids
        session.sortNext([.delete, .keep, .delete, .keep, .keep, .delete])
        let marked = [ids[0], ids[2], ids[5]]
        XCTAssertEqual(session.state.markedInOrder, marked)

        let outcome = await session.emptyTrash()

        XCTAssertEqual(outcome, .deleted(count: 3, undeletable: 0))
        XCTAssertEqual(session.lastChange, .trashEmptied(count: 3))
        XCTAssertFalse(session.isEmptyingTrash)
        // Out of the session and its trash; the photo on screen stays put.
        XCTAssertTrue(session.state.markedIDs.isEmpty)
        XCTAssertEqual(session.state.assetIDs, ids.filter { !marked.contains($0) })
        XCTAssertEqual(session.state.history.map(\.assetID), [ids[1], ids[3], ids[4]])
        XCTAssertEqual(session.state.currentAssetID, ids[6])
        XCTAssertEqual(session.state.position, 4)
        XCTAssertEqual(session.state.total, 33)
        // Out of Photos.
        XCTAssertEqual(fixture.library.photoIDs(inAlbum: session.albumID), session.state.assetIDs)
        XCTAssertTrue(marked.allSatisfy { fixture.library.imageName(for: $0) == nil })
        let metadata = await fixture.library.metadata(for: marked)
        XCTAssertTrue(metadata.isEmpty)
        // Written through and saved right away, not a moment later.
        assertRecord(fixture.record, matches: session.state)
        XCTAssertEqual(try savedSessions(in: fixture.container).first?.state, session.state)
    }

    func testEmptyTrashChangesNothingWhenThePersonDeclines() async {
        let fixture = SessionFixture(deletion: .cancel)
        let session = fixture.session
        session.sortNext([.delete, .keep, .delete])
        let before = session.state
        let lastChange = session.lastChange

        let outcome = await session.emptyTrash()

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(session.state, before)
        XCTAssertEqual(session.lastChange, lastChange)
        XCTAssertFalse(session.isEmptyingTrash)
        XCTAssertEqual(fixture.library.photoIDs(inAlbum: session.albumID), fixture.ids, "nothing left Photos")
        assertRecord(fixture.record, matches: before)
    }

    func testEmptyTrashReportsAFailureAndChangesNothing() async {
        let fixture = SessionFixture(deletion: .fail)
        let session = fixture.session
        session.sortNext([.delete, .keep, .delete])
        let before = session.state
        let lastChange = session.lastChange

        let outcome = await session.emptyTrash()

        guard case .failed(let message) = outcome else {
            return XCTFail("Expected .failed, got \(outcome)")
        }
        XCTAssertFalse(message.isEmpty, "the review screen has something to explain")
        XCTAssertEqual(session.state, before)
        XCTAssertEqual(session.lastChange, lastChange)
        XCTAssertFalse(session.isEmptyingTrash)
        XCTAssertEqual(fixture.library.photoIDs(inAlbum: session.albumID), fixture.ids)
        assertRecord(fixture.record, matches: before)
    }

    func testIsEmptyingTrashOnlyWhileWaitingForPhotos() async {
        let answers: [Result<DeletionReport, PhotoDeletionError>] = [
            .success(DeletionReport(deleted: ["p1", "p3"], missing: [], undeletable: [])),
            .failure(.cancelled),
            .failure(.failed("The operation couldn't be completed.")),
        ]
        for answer in answers {
            let library = StubPhotoLibrary()
            let systemPrompt = Gate()
            library.deletionGate = systemPrompt
            library.deletionResult = answer
            let fixture = SessionFixture(library: library, albumID: "album", title: "Album", assetIDs: ["p1", "p2", "p3", "p4"])
            let session = fixture.session
            session.sortNext([.delete, .keep, .delete])
            XCTAssertFalse(session.isEmptyingTrash)

            let emptying = Task { await session.emptyTrash() }
            await pollUntil("Photos is asked to delete (\(answer))") { systemPrompt.isHolding }
            XCTAssertTrue(session.isEmptyingTrash, "while the system prompt is up (\(answer))")

            // Tapping "Empty trash" again meanwhile doesn't ask a second time.
            let again = await session.emptyTrash()
            XCTAssertEqual(again, .deleted(count: 0, undeletable: 0))
            XCTAssertEqual(library.deletionRequests, [["p1", "p3"]])
            XCTAssertTrue(session.isEmptyingTrash)

            systemPrompt.open()
            _ = await emptying.value
            XCTAssertFalse(session.isEmptyingTrash, "after the answer (\(answer))")
        }
    }

    func testEmptyTrashWithNothingMarkedDoesNotAskPhotos() async {
        let library = StubPhotoLibrary()
        let fixture = SessionFixture(library: library, albumID: "album", title: "Album", assetIDs: ["p1", "p2"])
        fixture.session.sortNext([.keep])

        let outcome = await fixture.session.emptyTrash()

        XCTAssertEqual(outcome, .deleted(count: 0, undeletable: 0))
        XCTAssertTrue(library.deletionRequests.isEmpty)
        XCTAssertEqual(fixture.session.lastChange, .decided(SortDecision(assetID: "p1", action: .keep)))
    }

    func testEmptyTrashAlsoDropsPhotosThatWereAlreadyDeletedElsewhere() async {
        let fixture = SessionFixture()
        let session = fixture.session
        let ids = fixture.ids
        session.sortNext([.delete, .delete, .delete])
        fixture.library.remove([ids[1]])

        let outcome = await session.emptyTrash()

        XCTAssertEqual(outcome, .deleted(count: 2, undeletable: 0), "only the photos Photos actually deleted are counted")
        XCTAssertEqual(session.lastChange, .trashEmptied(count: 2))
        XCTAssertTrue(session.state.markedIDs.isEmpty)
        XCTAssertEqual(session.state.assetIDs, Array(ids.dropFirst(3)))
        XCTAssertEqual(session.state.currentAssetID, ids[3])
        assertRecord(fixture.record, matches: session.state)
    }

    func testPhotosThatPhotosWontDeleteStayInTheTrash() async {
        let library = StubPhotoLibrary()
        library.deletionResult = .success(DeletionReport(deleted: ["p1", "p5"], missing: [], undeletable: ["p3"]))
        let fixture = SessionFixture(library: library, albumID: "album", title: "Album", assetIDs: (1...6).map { "p\($0)" })
        let session = fixture.session
        session.sortNext([.delete, .keep, .delete, .keep, .delete])

        let outcome = await session.emptyTrash()

        XCTAssertEqual(library.deletionRequests, [["p1", "p3", "p5"]], "the whole trash, in session order")
        XCTAssertEqual(outcome, .deleted(count: 2, undeletable: 1))
        XCTAssertEqual(session.lastChange, .trashEmptied(count: 2))
        XCTAssertEqual(session.state.markedInOrder, ["p3"])
        XCTAssertEqual(session.state.assetIDs, ["p2", "p3", "p4", "p6"])
        XCTAssertEqual(session.state.currentAssetID, "p6")
        assertRecord(fixture.record, matches: session.state)
    }

    /// Photos sees nothing without access, so it reports every photo missing. If access went
    /// away while the system prompt was up (or wasn't there to begin with), or went from limited
    /// to full meanwhile, "missing" says nothing about the photos: they all stay in the trash,
    /// sorted as they were, and count as not deleted.
    func testWithoutFullAccessThroughoutPhotosThatPhotosCantSeeStayInTheTrash() async throws {
        let changes: [(asked: LibraryAccess, answered: LibraryAccess)] = [
            (.authorized, .denied), (.authorized, .restricted), (.denied, .denied), (.limited, .authorized), (.authorized, .limited),
        ]
        for change in changes {
            let library = StubPhotoLibrary()
            library.access = change.asked
            let prompt = Gate()
            library.deletionGate = prompt
            library.deletionResult = .success(DeletionReport(deleted: [], missing: ["p1", "p3", "p4"], undeletable: []))
            let fixture = SessionFixture(library: library, albumID: "album", title: "Album", assetIDs: (1...6).map { "p\($0)" })
            let session = fixture.session
            session.sortNext([.delete, .keep, .delete, .delete, .keep])
            let before = session.state

            let emptying = Task { await session.emptyTrash() }
            await pollUntil("the system prompt is up") { prompt.isHolding }
            library.access = change.answered
            prompt.open()
            let outcome = await emptying.value

            let label = "\(change.asked) → \(change.answered)"
            XCTAssertEqual(outcome, .deleted(count: 0, undeletable: 3), label)
            XCTAssertEqual(session.state, before, "the trash and the undo history are unchanged: \(label)")
            XCTAssertEqual(session.state.markedInOrder, ["p1", "p3", "p4"], label)
            XCTAssertEqual(session.lastChange, .trashEmptied(count: 0), label)
            assertRecord(fixture.record, matches: before)
            XCTAssertEqual(try savedSessions(in: fixture.container).first?.state, before, label)
        }
    }

    /// With limited access Photos can't tell a photo outside the person's selection from one
    /// that is gone, so a photo it reports missing stays in the trash, counted as not deleted.
    func testWithLimitedAccessPhotosThatPhotosCantFindStayInTheTrash() async {
        let library = StubPhotoLibrary()
        library.access = .limited
        library.deletionResult = .success(DeletionReport(deleted: ["p1"], missing: ["p3"], undeletable: []))
        let fixture = SessionFixture(library: library, albumID: "recents", title: "Recents", assetIDs: (1...5).map { "p\($0)" })
        let session = fixture.session
        session.sortNext([.delete, .keep, .delete])

        let outcome = await session.emptyTrash()

        XCTAssertEqual(outcome, .deleted(count: 1, undeletable: 1))
        XCTAssertEqual(session.state.markedInOrder, ["p3"])
        XCTAssertEqual(session.state.assetIDs, ["p2", "p3", "p4", "p5"])
        assertRecord(fixture.record, matches: session.state)
    }

    // MARK: Library changes

    func testReconcileDropsPhotosThatLeftTheAlbumAndSaysSo() {
        let fixture = SessionFixture()
        let session = fixture.session
        let ids = fixture.ids
        session.sortNext([.keep, .delete, .keep])
        let album = ids.filter { $0 != ids[1] }

        session.reconcile(withAlbumAssetIDs: album)

        XCTAssertEqual(session.lastChange, .reconciled)
        XCTAssertTrue(session.state.markedIDs.isEmpty)
        XCTAssertEqual(session.state.currentAssetID, ids[3])
        XCTAssertEqual(session.state.total, ids.count - 1)
        assertRecord(fixture.record, matches: session.state)

        session.decide(.keep)
        session.reconcile(withAlbumAssetIDs: album)
        XCTAssertEqual(session.lastChange, .decided(SortDecision(assetID: ids[3], action: .keep)), "nothing changed, so nothing is reported")
    }
}
