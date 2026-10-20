import XCTest
@testable import Piq

final class SortingStateTests: XCTestCase {
    private let ids = (1...6).map { "a\($0)" }

    func testStartsOnTheFirstPhoto() {
        let state = SortingState(assetIDs: ids)
        XCTAssertEqual(state.currentAssetID, "a1")
        XCTAssertEqual(state.position, 1)
        XCTAssertEqual(state.total, 6)
        XCTAssertEqual(state.progress, 0)
        XCTAssertFalse(state.canUndo)
        XCTAssertFalse(state.hasProgress)
        XCTAssertFalse(state.isComplete)
    }

    func testDecisionsAdvanceAndOnlyDeleteMarks() {
        var state = SortingState(assetIDs: ids)
        XCTAssertEqual(state.apply(.keep), SortDecision(assetID: "a1", action: .keep))
        XCTAssertEqual(state.apply(.delete), SortDecision(assetID: "a2", action: .delete))
        XCTAssertEqual(state.currentAssetID, "a3")
        XCTAssertEqual(state.position, 3)
        XCTAssertEqual(state.sortedCount, 2)
        XCTAssertEqual(state.markedIDs, ["a2"])
        XCTAssertEqual(state.keptCount, 1)
        XCTAssertEqual(state.remainingCount, 4)
        XCTAssertEqual(state.progress, 2.0 / 6.0, accuracy: 0.0001)
    }

    func testUndoGoesBackAndReversesTheDecision() {
        var state = SortingState(assetIDs: ids)
        state.apply(.keep)
        state.apply(.delete)
        XCTAssertEqual(state.undo(), SortDecision(assetID: "a2", action: .delete))
        XCTAssertEqual(state.currentAssetID, "a2")
        XCTAssertTrue(state.markedIDs.isEmpty)
        XCTAssertEqual(state.undo(), SortDecision(assetID: "a1", action: .keep))
        XCTAssertEqual(state.currentAssetID, "a1")
        XCTAssertNil(state.undo())
    }

    func testCompletesAfterTheLastPhoto() {
        var state = SortingState(assetIDs: ids)
        for _ in ids { state.apply(.keep) }
        XCTAssertTrue(state.isComplete)
        XCTAssertNil(state.currentAssetID)
        XCTAssertEqual(state.position, 6, "the counter stays at 6 of 6")
        XCTAssertEqual(state.progress, 1)
        XCTAssertNil(state.apply(.delete))
        XCTAssertEqual(state.undo()?.assetID, "a6")
        XCTAssertFalse(state.isComplete)
    }

    func testEmptyAlbum() {
        let state = SortingState(assetIDs: [])
        XCTAssertTrue(state.isComplete)
        XCTAssertNil(state.currentAssetID)
        XCTAssertEqual(state.position, 0)
        XCTAssertEqual(state.progress, 0)
    }

    func testRestoreKeepsPhotosSortedAndCountsThemAsKept() {
        var state = SortingState(assetIDs: ids)
        state.apply(.delete)
        state.apply(.delete)
        state.apply(.keep)
        state.unmark(["a1", "a3", "zzz"])
        XCTAssertEqual(state.markedIDs, ["a2"])
        XCTAssertEqual(state.sortedCount, 3)
        XCTAssertEqual(state.keptCount, 2)
        XCTAssertEqual(state.currentAssetID, "a4")
    }

    func testMarkedInOrderFollowsTheSession() {
        var state = SortingState(assetIDs: ids)
        for action in [SwipeAction.delete, .keep, .delete, .delete] { state.apply(action) }
        XCTAssertEqual(state.markedInOrder, ["a1", "a3", "a4"])
    }

    func testWindowIsCurrentPlusLookahead() {
        var state = SortingState(assetIDs: ids)
        XCTAssertEqual(state.window(lookahead: 3), ["a1", "a2", "a3", "a4"])
        for _ in 0..<4 { state.apply(.keep) }
        XCTAssertEqual(state.window(lookahead: 3), ["a5", "a6"])
        XCTAssertEqual(state.upcomingAssetIDs(3), ["a6"])
        state.apply(.keep)
        state.apply(.keep)
        XCTAssertEqual(state.window(lookahead: 3), [])
    }

    func testRemoveDropsPhotosFromQueueHistoryAndTrash() {
        var state = SortingState(assetIDs: ids)
        state.apply(.keep)
        state.apply(.delete)
        state.apply(.delete)
        state.remove(["a2", "a5"])
        XCTAssertEqual(state.assetIDs, ["a1", "a3", "a4", "a6"])
        XCTAssertEqual(state.history.map(\.assetID), ["a1", "a3"])
        XCTAssertEqual(state.markedIDs, ["a3"])
        XCTAssertEqual(state.currentAssetID, "a4")
    }

    func testReconcileDropsPhotosDeletedElsewhere() {
        var state = SortingState(assetIDs: ids)
        state.apply(.keep)
        state.apply(.delete)
        // a2 (sorted, in the trash) and a3 (on screen) were deleted in Photos.
        XCTAssertTrue(state.reconcile(albumAssetIDs: ["a1", "a4", "a5", "a6"]))
        XCTAssertEqual(state.assetIDs, ["a1", "a4", "a5", "a6"])
        XCTAssertEqual(state.history.map(\.assetID), ["a1"])
        XCTAssertTrue(state.markedIDs.isEmpty)
        XCTAssertEqual(state.currentAssetID, "a4")
        XCTAssertEqual(state.position, 2)
    }

    func testReconcileQueuesNewPhotosInAlbumOrder() {
        var state = SortingState(assetIDs: ids)
        state.apply(.keep)
        state.apply(.delete)
        // a0 is older than everything; a7 is newer. Neither has been sorted yet.
        XCTAssertTrue(state.reconcile(albumAssetIDs: ["a0"] + ids + ["a7"]))
        XCTAssertEqual(state.assetIDs, ["a1", "a2", "a0", "a3", "a4", "a5", "a6", "a7"])
        XCTAssertEqual(state.currentAssetID, "a0")
        XCTAssertEqual(state.markedIDs, ["a2"])
        XCTAssertEqual(state.total, 8)
    }

    func testReconcileReopensAFinishedSessionWhenPhotosArrive() {
        var state = SortingState(assetIDs: ids)
        for _ in ids { state.apply(.keep) }
        XCTAssertTrue(state.isComplete)
        state.reconcile(albumAssetIDs: ids + ["a7"])
        XCTAssertEqual(state.currentAssetID, "a7")
        XCTAssertEqual(state.position, 7)
    }

    func testReconcileWithoutChangesReportsNothing() {
        var state = SortingState(assetIDs: ids)
        state.apply(.delete)
        XCTAssertFalse(state.reconcile(albumAssetIDs: ids))
        XCTAssertEqual(state.markedIDs, ["a1"])
    }

    /// `reconcile` takes shortcuts to stay quick for a Recents of tens of thousands of photos, so
    /// it is checked against the rule written out the slow, obvious way, on thousands of random
    /// sessions and albums: photos gone, photos new, the album reordered, duplicates, limited
    /// access. The same sessions on every run.
    func testReconcileFollowsTheRuleOnRandomSessions() {
        var random = SeededGenerator(seed: 2026)
        let pool = (0..<12).map { "p\($0)" }
        var changes = 0
        for trial in 0..<5_000 {
            var state = SortingState(assetIDs: Array(pool.shuffled(using: &random).prefix(Int.random(in: 0...10, using: &random))))
            for _ in 0..<Int.random(in: 0...state.total, using: &random) {
                state.apply(Bool.random(using: &random) ? .delete : .keep)
            }
            if Bool.random(using: &random), let restored = state.markedIDs.randomElement(using: &random) {
                state.unmark([restored])
            }
            var album = switch Int.random(in: 0..<5, using: &random) {
            case 0: state.assetIDs
            case 1: state.assetIDs + ["new-\(trial)"]
            case 2: state.assetIDs.filter { _ in Int.random(in: 0..<4, using: &random) > 0 }
            case 3: Array(pool.shuffled(using: &random).prefix(Int.random(in: 0...12, using: &random)))
            default: (state.assetIDs + pool.prefix(3)).shuffled(using: &random)
            }
            if Int.random(in: 0..<6, using: &random) == 0, let duplicate = album.randomElement(using: &random) {
                album.insert(duplicate, at: Int.random(in: 0...album.count, using: &random))
            }
            let keepingSortedPhotos = Bool.random(using: &random)
            let expected = Self.reconciledTheObviousWay(state, albumAssetIDs: album, keepingSortedPhotos: keepingSortedPhotos)

            var reconciled = state
            let changed = reconciled.reconcile(albumAssetIDs: album, keepingSortedPhotos: keepingSortedPhotos)

            guard reconciled == expected, changed == (expected != state) else {
                XCTFail("Trial \(trial): \(state) with album \(album), keeping sorted photos: \(keepingSortedPhotos). Got \(reconciled) (changed: \(changed)), expected \(expected)")
                return
            }
            changes += changed ? 1 : 0
        }
        XCTAssertGreaterThan(changes, 1_000, "the random albums change most sessions")
        XCTAssertLessThan(changes, 4_900, "and leave some as they were")
    }

    /// The rule `reconcile` follows, the slow, obvious way: the sorted photos the album still has
    /// (all of them with `keepingSortedPhotos`), in the order they were sorted, then the album's
    /// other photos in album order; the trash keeps the sorted photos it had.
    private static func reconciledTheObviousWay(_ state: SortingState, albumAssetIDs: [String], keepingSortedPhotos: Bool) -> SortingState {
        let present = Set(albumAssetIDs)
        let kept = keepingSortedPhotos ? state.history : state.history.filter { present.contains($0.assetID) }
        var seen = Set(kept.map(\.assetID))
        let queue = albumAssetIDs.filter { seen.insert($0).inserted }
        return SortingState(
            assetIDs: kept.map(\.assetID) + queue,
            currentIndex: kept.count,
            markedIDs: state.markedIDs.intersection(kept.map(\.assetID)),
            history: kept
        )
    }

    /// The same answer as `SortingSession.resumePoint`, from memory.
    func testResumePointFollowsTheSession() {
        var state = SortingState(assetIDs: ids)
        XCTAssertNil(state.resumePoint, "nothing sorted yet")
        state.apply(.keep)
        state.apply(.delete)
        XCTAssertEqual(state.resumePoint, ResumePoint(position: 3, total: 6, markedCount: 1, isComplete: false))
        for _ in 0..<4 { state.apply(.keep) }
        XCTAssertEqual(state.resumePoint, ResumePoint(position: 6, total: 6, markedCount: 1, isComplete: true), "a trash left to review")
        state.unmark(["a2"])
        XCTAssertNil(state.resumePoint, "everything sorted and nothing in the trash")
    }

    func testDuplicateIdentifiersAreIgnored() {
        let state = SortingState(assetIDs: ["a1", "a2", "a1", "a3"])
        XCTAssertEqual(state.assetIDs, ["a1", "a2", "a3"])
    }

    func testRestoringFromStorageRepairsABrokenHistory() {
        // History says a1 then a9 (not in the list), the index says 3 photos are sorted,
        // and the trash holds a2 plus an unsorted photo.
        let state = SortingState(
            assetIDs: ids,
            currentIndex: 3,
            markedIDs: ["a2", "a5"],
            history: [SortDecision(assetID: "a1", action: .keep), SortDecision(assetID: "a9", action: .keep)]
        )
        XCTAssertEqual(state.history, [
            SortDecision(assetID: "a1", action: .keep),
            SortDecision(assetID: "a2", action: .delete),
            SortDecision(assetID: "a3", action: .keep),
        ])
        XCTAssertEqual(state.markedIDs, ["a2"], "only sorted photos can be in the trash")
        XCTAssertEqual(state.currentAssetID, "a4")
    }

    func testRestoringClampsTheIndex() {
        let state = SortingState(assetIDs: ids, currentIndex: 99, markedIDs: [String](), history: [])
        XCTAssertTrue(state.isComplete)
        XCTAssertEqual(state.sortedCount, 6)
    }
}

/// Random numbers from a fixed seed (SplitMix64), so a randomized test checks the same cases on
/// every run.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
