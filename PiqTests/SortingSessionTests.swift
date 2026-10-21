import SwiftData
import XCTest
@testable import Piq

@MainActor
final class SortingSessionTests: XCTestCase {
    private static let ids = (1...8).map { "photo-\($0)" }

    /// `ids` with the given actions applied in order.
    private static func state(after actions: [SwipeAction], assetIDs: [String] = ids) -> SortingState {
        var state = SortingState(assetIDs: assetIDs)
        for action in actions { state.apply(action) }
        return state
    }

    // MARK: Creating

    func testANewSessionStartsUntouchedOnTheFirstPhoto() throws {
        let store = RecordStore()
        let start = Date()

        let record = store.insert(albumID: "album-1", title: "Iceland 2026", assetIDs: Self.ids + ["photo-3"])

        XCTAssertEqual(record.albumID, "album-1")
        XCTAssertEqual(record.albumTitle, "Iceland 2026")
        XCTAssertEqual(record.photos?.assetIDs, Self.ids, "duplicates are dropped")
        XCTAssertEqual(record.photoCount, Self.ids.count)
        XCTAssertTrue(record.decisions.isEmpty, "no decisions yet")
        XCTAssertEqual(record.state, SortingState(assetIDs: Self.ids))
        XCTAssertEqual(record.state.currentAssetID, "photo-1")
        XCTAssertFalse(record.isInEarlierLayout)
        XCTAssertGreaterThanOrEqual(record.createdAt, start)
        XCTAssertGreaterThanOrEqual(record.updatedAt, start)
    }

    // MARK: State

    func testStateRoundTripsThroughTheStoredFields() throws {
        let store = RecordStore()
        let record = store.insert(assetIDs: Self.ids)
        let state = Self.state(after: [.delete, .keep, .delete, .keep, .delete])

        record.state = state

        XCTAssertEqual(record.state, state)
        XCTAssertEqual(record.state.markedInOrder, ["photo-1", "photo-3", "photo-5"])
        assertRecord(record, matches: state)
    }

    /// Saved after every decision, so it stays small: one letter per sorted photo, by its
    /// action, in upper case while the photo is in the trash. A restored photo keeps its
    /// decision, in lower case.
    func testDecisionsAreStoredAsOneLetterPerSortedPhoto() {
        let store = RecordStore()
        let record = store.insert(assetIDs: Self.ids)
        var state = Self.state(after: [.delete, .keep, .keep, .delete])

        record.state = state
        XCTAssertEqual(String(decoding: record.decisions, as: UTF8.self), "DkkD")

        state.unmark(["photo-1"])
        record.state = state
        XCTAssertEqual(String(decoding: record.decisions, as: UTF8.self), "dkkD")
        XCTAssertEqual(record.state, state)
        XCTAssertEqual(record.state.history.first, SortDecision(assetID: "photo-1", action: .delete), "the undo history still knows it was a delete")
    }

    /// A letter written by a later build with more actions: the trash says whether it was a
    /// delete, and the rest of the session reads as it should.
    func testADecisionThisBuildDoesNotKnowIsReadFromTheTrash() {
        let store = RecordStore()
        let record = store.insert(assetIDs: Self.ids)

        record.decisions = Data("kEeD".utf8)
        record.cursor = 4

        XCTAssertEqual(record.state.history.map(\.action), [.keep, .delete, .keep, .delete])
        XCTAssertEqual(record.state.markedInOrder, ["photo-2", "photo-4"])
        XCTAssertEqual(record.state.currentAssetID, "photo-5")
        XCTAssertEqual(record.resumePoint, ResumePoint(position: 5, total: 8, markedCount: 2, isComplete: false))
    }

    func testMoreDecisionsThanPhotosLeavesTheSessionComplete() {
        let store = RecordStore()
        let record = store.insert(assetIDs: Array(Self.ids.prefix(2)))

        record.decisions = Data("kDkk".utf8)

        XCTAssertEqual(record.state.sortedCount, 2)
        XCTAssertTrue(record.state.isComplete)
        XCTAssertEqual(record.state.markedInOrder, ["photo-2"])
        XCTAssertEqual(record.resumePoint, ResumePoint(position: 2, total: 2, markedCount: 1, isComplete: true))
    }

    /// How a session controller saves: only the fields that changed, never reading the stored
    /// ones. The record must end up exactly as the `state` setter would leave it.
    func testWritingOverTheStoredStateLeavesTheSameRecordAsTheSetter() {
        let store = RecordStore()
        let record = store.insert(assetIDs: Self.ids)
        var state = record.state
        func write(_ change: (inout SortingState) -> Void, line: UInt = #line) {
            let old = state
            change(&state)
            record.write(state, over: old, touch: true)
            assertRecord(record, matches: state, line: line)
            XCTAssertEqual(record.state, state, line: line)
        }

        write { $0.apply(.delete) }
        write { $0.apply(.keep) }
        write { $0.apply(.delete) }
        write { _ = $0.undo() }
        write { $0.unmark(["photo-1"]) }
        write { $0.apply(.delete) }
        // A library change: photo-2 is gone and photo-9, older than the rest, arrives.
        write { _ = $0.reconcile(albumAssetIDs: ["photo-9"] + Self.ids.filter { $0 != "photo-2" }) }
        write { $0.remove(["photo-3"]) }
        XCTAssertEqual(record.state.markedInOrder, [])
        XCTAssertEqual(record.state.currentIndex, 1)
        XCTAssertEqual(record.photoCount, 7)
    }

    /// How a session controller saves a decision or an undo: one letter set, one undo-log entry
    /// added or taken off. The record must end up exactly as writing the whole state would leave
    /// it.
    func testRecordingAndTakingBackDecisionsMatchesWritingTheState() throws {
        let store = RecordStore()
        let record = store.insert(assetIDs: Self.ids)
        var state = record.state

        for action in [SwipeAction.delete, .keep, .keep, .delete] {
            XCTAssertNotNil(recordDecision(action, in: &state, on: record))
            assertRecord(record, matches: state)
        }
        XCTAssertEqual(record.undoLog?.count, UndoLog.entrySize, "sorted straight through: one run")
        for _ in 0..<2 {
            XCTAssertNotNil(recordUndo(in: &state, on: record))
            assertRecord(record, matches: state)
        }
        XCTAssertEqual(record.state, state)
        XCTAssertEqual(String(decoding: record.decisions, as: UTF8.self), "Dk")
    }

    /// A record holding more letters than photos (written by an earlier build, or damaged) reads
    /// as a finished session. The first change written to it leaves no letter past its photos, so
    /// no stale letter is left to sort a photo queued later.
    func testEveryWriteLeavesOneLetterPerSortedPhoto() throws {
        let store = RecordStore()
        let ids = Array(Self.ids.prefix(4))
        func recordWithExtraLetters() -> SortingSession {
            let record = store.insert(albumID: UUID().uuidString, assetIDs: ids)
            record.decisions = Data("kDkkdd".utf8)
            record.cursor = nil
            record.undoLog = nil
            XCTAssertTrue(record.state.isComplete)
            return record
        }

        // An undo.
        var record = recordWithExtraLetters()
        var state = record.state
        XCTAssertNotNil(recordUndo(in: &state, on: record))
        assertRecord(record, matches: state)
        // A decision after it.
        XCTAssertNotNil(recordDecision(.delete, in: &state, on: record))
        assertRecord(record, matches: state)

        // A photo arriving in the album, which changes neither the decisions nor the trash.
        record = recordWithExtraLetters()
        state = record.state
        let old = state
        state.reconcile(albumAssetIDs: ids + ["photo-9"])
        record.write(state, over: old, touch: false)
        assertRecord(record, matches: state)
        XCTAssertEqual(record.state.currentAssetID, "photo-9", "the new photo isn't sorted by a stale letter")
    }

    /// The point of keeping the photo list in a record of its own: saving a decision writes the
    /// session's small record and leaves the list alone, however long it is. Only a change to
    /// the list itself (a library change, here) writes it.
    func testADecisionChangesTheSessionRecordButNotItsPhotoList() throws {
        let store = RecordStore()
        let context = store.container.mainContext
        let record = store.insert(assetIDs: Self.ids)
        try context.save()
        var state = record.state

        for action in [SwipeAction.delete, .keep] {
            XCTAssertNotNil(recordDecision(action, in: &state, on: record))
            XCTAssertEqual(context.changedModelsArray.count, 1, "\(action)")
            XCTAssertTrue(context.changedModelsArray.first is SortingSession, "\(action): only the session record")
            try context.save()
        }
        let beforeKeep = state
        state.apply(.keep)
        record.write(state, over: beforeKeep, touch: true)
        XCTAssertFalse(context.changedModelsArray.contains { $0 is SessionPhotos }, "nor when the whole state is written")
        try context.save()
        let old = state
        state.undo()
        state.unmark(["photo-1"])
        record.write(state, over: old, touch: true)
        XCTAssertFalse(context.changedModelsArray.contains { $0 is SessionPhotos }, "undo and restore leave the list alone too")
        try context.save()

        let beforeChange = state
        state.reconcile(albumAssetIDs: Self.ids + ["photo-9"])
        record.write(state, over: beforeChange, touch: false)
        XCTAssertTrue(context.changedModelsArray.contains { $0 is SessionPhotos }, "a new photo is a change to the list")
        try context.save()
        XCTAssertEqual(try savedSessions(in: store.container).first?.state, state)
    }

    /// `updatedAt` says which session the person worked on last, so the picker can select it on
    /// launch. Changes the library makes (written with `touch: false`, and through the `state`
    /// setter) leave it alone.
    func testOnlyThePersonsChangesCountAsWorkingOnTheSession() async throws {
        let store = RecordStore()
        let record = store.insert(assetIDs: Self.ids)
        let created = record.updatedAt
        try await Task.sleep(for: .milliseconds(5))

        var state = record.state
        state.reconcile(albumAssetIDs: Self.ids + ["photo-9"])
        record.state = state
        let old = state
        state.reconcile(albumAssetIDs: Array(Self.ids.dropFirst()))
        record.write(state, over: old, touch: false)
        XCTAssertEqual(record.updatedAt, created, "library changes")

        let beforeDecision = state
        state.apply(.keep)
        record.write(state, over: beforeDecision, touch: true)
        XCTAssertGreaterThan(record.updatedAt, created, "a decision")
    }

    func testStateSurvivesSavingAndFetchingInAFreshContext() throws {
        let store = RecordStore()
        let record = store.insert(albumID: "album-1", title: "Iceland 2026", assetIDs: Self.ids)
        let state = Self.state(after: [.keep, .delete, .delete, .keep])
        record.state = state

        try store.container.mainContext.save()

        XCTAssertEqual(try savedSessions(in: store.container), [SavedSession(albumID: "album-1", albumTitle: "Iceland 2026", state: state)])
    }

    /// The app's way to create a session: the store inserts it, then attaches its photo list (a
    /// record of its own), and saves both.
    func testTheStoreSavesANewSessionWithItsPhotoList() throws {
        let container = PreviewSupport.inMemoryContainer()
        let store = SessionStore(context: container.mainContext)

        let record = store.insertSession(albumID: "album-1", title: "Iceland 2026", assetIDs: Self.ids + ["photo-3"])

        XCTAssertFalse(container.mainContext.hasChanges, "saved")
        XCTAssertTrue(record.photos?.session === record, "the list belongs to the session")
        assertRecord(record, matches: SortingState(assetIDs: Self.ids))
        XCTAssertEqual(try savedSessions(in: container), [SavedSession(albumID: "album-1", albumTitle: "Iceland 2026", state: SortingState(assetIDs: Self.ids))])
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<SessionPhotos>()), 1)
    }

    // MARK: The photo list

    /// Each identifier's UTF-8 bytes after its length, rather than the keyed archive SwiftData
    /// makes of a `[String]`, which for a Recents of 50,000 photos took about 0.2 s to save at every
    /// library change (see `PersistenceSaveCostTests`).
    func testThePhotoListIsStoredAsPackedBytes() {
        let store = RecordStore()
        let record = store.insert(assetIDs: ["abc", "de"])

        XCTAssertEqual(record.photos.map { Array($0.packedIDs) }, [3, 97, 98, 99, 2, 100, 101])
        XCTAssertEqual(record.photos?.assetIDs, ["abc", "de"])
    }

    /// Lengths rather than a separator, so no identifier can split in two or merge with the next.
    func testThePhotoListKeepsAnyIdentifier() throws {
        let ids = [
            "B84E8479-475C-4727-A4A4-B77AA9980897/L0/001", "", "a\nb", "a,b", "\0",
            String(repeating: "x", count: 127), String(repeating: "y", count: 128), String(repeating: "z", count: 20_000), "Café 😀",
        ]
        let store = RecordStore()
        let record = store.insert(assetIDs: ids)
        try store.container.mainContext.save()

        XCTAssertEqual(record.photos?.assetIDs, ids)
        XCTAssertEqual(try savedSessions(in: store.container).first?.state.assetIDs, ids)
        XCTAssertEqual(SessionPhotos.unpack(SessionPhotos.pack([])), [])
        XCTAssertEqual(SessionPhotos.unpack(SessionPhotos.pack([""])), [""])
    }

    /// Bytes that don't parse (cut off, or damaged) end the list at the last whole identifier
    /// rather than trapping.
    func testDamagedPhotoListBytesEndTheListWithoutTrapping() {
        let packed = SessionPhotos.pack(["abc", "de"])

        XCTAssertEqual(SessionPhotos.unpack(packed.prefix(6)), ["abc"], "an identifier cut off")
        XCTAssertEqual(SessionPhotos.unpack(packed.prefix(4)), ["abc"])
        XCTAssertEqual(SessionPhotos.unpack(packed.dropFirst()), [], "a length past the end")
        XCTAssertEqual(SessionPhotos.unpack(Data([0x80])), [], "a length cut off")
        XCTAssertEqual(SessionPhotos.unpack(Data([0xFF, 0xFF, 0xFF, 0xFF, 0x0F, 0x61])), [], "an absurd length")
    }

    // MARK: Earlier builds

    /// Earlier builds kept the photo list, the index, the trash and the undo history in the
    /// session record: JSON-encoded decisions first, then the actions' names. Opening the store
    /// converts such a session, with its progress, trash and undo history.
    func testASessionSavedByAnEarlierBuildIsConvertedWhenTheStoreOpens() throws {
        let histories = [
            #"[{"assetID":"photo-1","action":"keep"},{"assetID":"photo-2","action":"delete"},{"assetID":"photo-3","action":"delete"}]"#,
            "keep,delete,delete",
        ]
        for stored in histories {
            let container = PreviewSupport.inMemoryContainer()
            let record = Self.insertInEarlierLayout(in: container, currentIndex: 3, markedIDs: ["photo-2"], historyData: Data(stored.utf8))

            _ = SessionStore(context: container.mainContext)

            let expected = SortingState(
                assetIDs: Self.ids,
                currentIndex: 3,
                markedIDs: ["photo-2"],
                history: [
                    SortDecision(assetID: "photo-1", action: .keep),
                    SortDecision(assetID: "photo-2", action: .delete),
                    SortDecision(assetID: "photo-3", action: .delete),
                ]
            )
            XCTAssertEqual(record.state, expected, stored)
            XCTAssertEqual(record.state.markedInOrder, ["photo-2"], "photo-3 was restored: \(stored)")
            assertRecord(record, matches: expected)
            XCTAssertNil(record.legacyAssetIDs)
            XCTAssertNil(record.legacyCurrentIndex)
            XCTAssertNil(record.legacyMarkedIDs)
            XCTAssertNil(record.legacyHistoryData)
            XCTAssertEqual(record.resumePoint, ResumePoint(position: 4, total: 8, markedCount: 1, isComplete: false))
            XCTAssertEqual(try savedSessions(in: container).first?.state, expected, "saved: \(stored)")
        }
    }

    func testAnUnreadableHistoryFromAnEarlierBuildIsRebuiltFromTheTrash() {
        // Garbage, an action this build doesn't know, and more decisions than photos.
        for stored in ["not json", "keep,edit,keep", Array(repeating: "keep", count: Self.ids.count + 1).joined(separator: ",")] {
            let container = PreviewSupport.inMemoryContainer()
            let record = Self.insertInEarlierLayout(in: container, currentIndex: 3, markedIDs: ["photo-2"], historyData: Data(stored.utf8))

            _ = SessionStore(context: container.mainContext)

            XCTAssertEqual(record.state.history, [
                SortDecision(assetID: "photo-1", action: .keep),
                SortDecision(assetID: "photo-2", action: .delete),
                SortDecision(assetID: "photo-3", action: .keep),
            ], stored)
            XCTAssertEqual(record.state.currentAssetID, "photo-4", stored)
        }
    }

    // MARK: Resume point

    func testNothingToResumeBeforeAnythingIsSorted() {
        let store = RecordStore()
        let record = store.insert(assetIDs: Self.ids)
        XCTAssertNil(record.resumePoint)

        record.state = Self.state(after: [.delete])
        var undone = record.state
        undone.undo()
        record.state = undone
        XCTAssertNil(record.resumePoint, "undoing everything is the same as never starting")
    }

    func testResumePointMidSessionIsTheNextPhotoToSort() {
        let store = RecordStore()
        let ids = (0..<400).map { "photo-\($0)" }
        let record = store.insert(assetIDs: ids)
        // 37 sorted, every eighth one marked: 4 in the trash.
        record.state = Self.state(after: (0..<37).map { $0 % 8 == 7 ? .delete : .keep }, assetIDs: ids)

        XCTAssertEqual(record.resumePoint, ResumePoint(position: 38, total: 400, markedCount: 4, isComplete: false))
        XCTAssertEqual(record.resumePoint, record.state.resumePoint)
    }

    func testNothingToResumeOnceEverythingIsSortedAndTheTrashIsEmpty() {
        let store = RecordStore()
        let record = store.insert(assetIDs: Self.ids)
        record.state = Self.state(after: Array(repeating: .keep, count: Self.ids.count))

        XCTAssertNil(record.resumePoint)
    }

    func testAFinishedSessionWithPhotosInTheTrashCanBeResumed() {
        let store = RecordStore()
        let record = store.insert(assetIDs: Self.ids)
        record.state = Self.state(after: [.keep, .delete, .keep, .keep, .keep, .delete, .keep, .keep])

        XCTAssertEqual(record.resumePoint, ResumePoint(position: 8, total: 8, markedCount: 2, isComplete: true))
    }

    func testAnEmptyAlbumHasNothingToResume() {
        let store = RecordStore()
        let record = store.insert(assetIDs: [])
        XCTAssertNil(record.resumePoint)
    }

    // MARK: Reset

    func testResetStartsOverWithTheAlbumsCurrentPhotos() {
        let store = RecordStore()
        let record = store.insert(albumID: "album-1", title: "Iceland", assetIDs: Self.ids)
        record.state = Self.state(after: [.delete, .keep, .delete])
        let newIDs = ["photo-9"] + Self.ids.dropFirst(2)
        let resetAt = Date()

        record.reset(assetIDs: newIDs, albumTitle: "Iceland 2026")

        XCTAssertEqual(record.albumID, "album-1")
        XCTAssertEqual(record.albumTitle, "Iceland 2026")
        XCTAssertEqual(record.state, SortingState(assetIDs: newIDs))
        assertRecord(record, matches: SortingState(assetIDs: newIDs))
        XCTAssertNil(record.resumePoint)
        XCTAssertGreaterThanOrEqual(record.createdAt, resetAt)
        XCTAssertGreaterThanOrEqual(record.updatedAt, resetAt)
    }

    // MARK: Helpers

    /// A session of `ids` as an earlier build stored it, all in the session record: what opening
    /// such a store leaves before `SessionStore` converts it (no photo list record, no decisions).
    private static func insertInEarlierLayout(in container: ModelContainer, currentIndex: Int, markedIDs: [String], historyData: Data) -> SortingSession {
        let record = SortingSession(albumID: "album", albumTitle: "Iceland 2026", assetIDs: [])
        container.mainContext.insert(record)
        if let photos = record.photos {
            container.mainContext.delete(photos)
        }
        record.photos = nil
        record.photoCount = 0
        record.legacyAssetIDs = ids
        record.legacyCurrentIndex = currentIndex
        record.legacyMarkedIDs = markedIDs
        record.legacyHistoryData = historyData
        return record
    }
}
