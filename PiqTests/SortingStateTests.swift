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

    /// New photos are queued unsorted in album order after the photo on screen, which stays on
    /// screen: one older than it comes up right after it, rather than taking its place (as it did
    /// before Previous and Next) or being left behind the cursor.
    func testReconcileQueuesNewPhotosInAlbumOrder() {
        var state = SortingState(assetIDs: ids)
        state.apply(.keep)
        state.apply(.delete)
        // a0 is older than everything; a7 is newer. Neither has been sorted yet.
        XCTAssertTrue(state.reconcile(albumAssetIDs: ["a0"] + ids + ["a7"]))
        XCTAssertEqual(state.assetIDs, ["a1", "a2", "a3", "a0", "a4", "a5", "a6", "a7"])
        XCTAssertEqual(state.currentAssetID, "a3", "the photo on screen stays")
        XCTAssertEqual(state.upcomingAssetIDs(1), ["a0"])
        XCTAssertEqual(state.markedIDs, ["a2"])
        XCTAssertEqual(state.total, 8)
        XCTAssertEqual(state.resumePoint?.position, 3)
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
    /// sessions (decided in any order, with photos skipped, revisited and decided again, undone and
    /// restored) and albums: photos gone, photos new, the album reordered, duplicates, limited
    /// access. The same sessions on every run.
    func testReconcileFollowsTheRuleOnRandomSessions() {
        var random = SeededGenerator(seed: 2026)
        let pool = (0..<12).map { "p\($0)" }
        var changes = 0
        for trial in 0..<5_000 {
            var state = SortingState(assetIDs: Array(pool.shuffled(using: &random).prefix(Int.random(in: 0...10, using: &random))))
            state.randomlyWorkedOn(using: &random)
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

    /// The rule `reconcile` follows, the slow, obvious way. A photo stays if the album lists it
    /// (or, with `keepingSortedPhotos`, if it is decided). The photos before the cursor that stay
    /// keep their order, then comes the photo on screen if it stays (the cursor stays on it), then
    /// the album's other photos in album order, then (`keepingSortedPhotos`) the decided photos
    /// after the cursor that the album doesn't list. Decisions, history and trash keep what stays.
    private static func reconciledTheObviousWay(_ state: SortingState, albumAssetIDs: [String], keepingSortedPhotos: Bool) -> SortingState {
        let listed = Set(albumAssetIDs)
        func stays(_ id: String) -> Bool { listed.contains(id) || (keepingSortedPhotos && state.decisions[id] != nil) }
        let head = state.assetIDs.prefix(state.currentIndex).filter(stays)
        let current = state.currentAssetID.map { stays($0) ? [$0] : [] } ?? []
        var seen = Set(head + current)
        let rest = albumAssetIDs.filter { seen.insert($0).inserted }
        let hidden = keepingSortedPhotos ? state.assetIDs.dropFirst(state.currentIndex + 1).filter { state.decisions[$0] != nil && !listed.contains($0) } : []
        let ids = head + current + rest + hidden
        let kept = Set(ids)
        return SortingState(
            assetIDs: ids,
            currentIndex: head.count,
            decisions: state.decisions.filter { kept.contains($0.key) },
            markedIDs: state.markedIDs.intersection(kept),
            history: state.history.filter { kept.contains($0.assetID) }
        )
    }

    /// The same answer as `SortingSession.resumePoint`, from memory: the first unsorted photo.
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

    // MARK: Previous and Next

    func testNextAndPreviousMoveWithoutDeciding() {
        var state = SortingState(assetIDs: ids)
        XCTAssertFalse(state.canGoBack, "nothing before the first photo")
        XCTAssertFalse(state.step(.previous))
        XCTAssertTrue(state.step(.next))
        XCTAssertTrue(state.step(.next))
        XCTAssertEqual(state.currentAssetID, "a3")
        XCTAssertEqual(state.position, 3)
        XCTAssertEqual(state.sortedCount, 0, "skipping decides nothing")
        XCTAssertEqual(state.progress, 0)
        XCTAssertFalse(state.canUndo, "moves aren't undoable")
        XCTAssertNil(state.resumePoint, "nothing worth resuming yet")
        XCTAssertTrue(state.step(.previous))
        XCTAssertEqual(state.currentAssetID, "a2")
        XCTAssertEqual(state.window(lookahead: 3), ["a2", "a3", "a4", "a5"], "the window follows the cursor")
    }

    /// A skipped photo stays unsorted: deciding the next ones doesn't bring it back, and the
    /// resume point is the first unsorted photo.
    func testASkippedPhotoStaysUnsorted() {
        var state = SortingState(assetIDs: ids)
        state.apply(.keep)
        state.step(.next)
        XCTAssertEqual(state.apply(.delete), SortDecision(assetID: "a3", action: .delete))
        XCTAssertEqual(state.currentAssetID, "a4")
        XCTAssertNil(state.verdict(for: "a2"))
        XCTAssertEqual(state.sortedCount, 2)
        XCTAssertEqual(state.remainingCount, 4)
        XCTAssertEqual(state.progress, 2.0 / 6.0, accuracy: 0.0001, "progress counts decisions")
        XCTAssertEqual(state.position, 4, "the counter follows the cursor")
        XCTAssertEqual(state.firstUnsortedIndex, 1)
        XCTAssertEqual(state.resumePoint, ResumePoint(position: 2, total: 6, markedCount: 1, isComplete: false))
    }

    /// Next on the last photo, or a decision there, moves past it: no photo on screen, and the
    /// session is complete only if nothing was skipped.
    func testMovingPastTheLastPhotoWithPhotosSkipped() {
        var state = SortingState(assetIDs: ids)
        state.step(.next)
        for _ in 0..<4 { state.apply(.keep) }
        XCTAssertEqual(state.currentAssetID, "a6")
        XCTAssertTrue(state.canGoForward, "Next on the last photo goes on to the end")
        XCTAssertTrue(state.step(.next))
        XCTAssertNil(state.currentAssetID)
        XCTAssertFalse(state.canGoForward)
        XCTAssertFalse(state.step(.next))
        XCTAssertFalse(state.isComplete, "a1 and a6 are unsorted")
        XCTAssertEqual(state.position, 6, "the counter stays at 6 of 6")
        XCTAssertEqual(state.resumePoint?.position, 1)
        XCTAssertTrue(state.goToFirstUnsorted())
        XCTAssertEqual(state.currentAssetID, "a1")
        state.apply(.delete)
        XCTAssertEqual(state.currentAssetID, "a2", "a decision moves on, even onto a decided photo")
        XCTAssertTrue(state.goToFirstUnsorted())
        XCTAssertEqual(state.currentAssetID, "a6", "the only photo left to sort")
        state.apply(.keep)
        XCTAssertTrue(state.isComplete)
        XCTAssertNil(state.firstUnsortedIndex)
        XCTAssertEqual(state.resumePoint, ResumePoint(position: 6, total: 6, markedCount: 1, isComplete: true))
        XCTAssertFalse(state.goToFirstUnsorted(), "already past the last photo")
    }

    /// Back on a decided photo, its decision shows (`verdict`) and a new one replaces it: the
    /// trash follows, the count of sorted photos doesn't change, and the cursor moves on.
    func testDecidingARevisitedPhotoReplacesItsDecision() {
        var state = SortingState(assetIDs: ids)
        state.apply(.delete)
        state.apply(.keep)
        state.step(.previous)
        state.step(.previous)
        XCTAssertEqual(state.verdict(for: "a1"), Verdict(action: .delete, isMarked: true))
        XCTAssertEqual(state.apply(.keep), SortDecision(assetID: "a1", action: .keep, replaced: Verdict(action: .delete, isMarked: true)))
        XCTAssertEqual(state.markedIDs, [], "out of the trash")
        XCTAssertEqual(state.sortedCount, 2)
        XCTAssertEqual(state.currentAssetID, "a2")
        XCTAssertEqual(state.verdict(for: "a2"), Verdict(action: .keep, isMarked: false))
        XCTAssertEqual(state.apply(.delete)?.replaced, Verdict(action: .keep, isMarked: false))
        XCTAssertEqual(state.markedIDs, ["a2"])
        XCTAssertEqual(state.keptCount, 1)
        XCTAssertEqual(state.history.count, 4, "every decision is in the undo history")
        XCTAssertEqual(state.currentAssetID, "a3")
    }

    /// Undo of a decision that replaced another puts the earlier one back exactly (a photo
    /// restored in Review comes back restored) and shows its photo, wherever the cursor was.
    func testUndoingAReplacementPutsBackTheEarlierDecision() {
        var state = SortingState(assetIDs: ids)
        state.apply(.delete)
        state.apply(.delete)
        state.unmark(["a1"])
        state.step(.previous)
        state.step(.previous)
        state.apply(.keep)
        state.step(.next)
        state.step(.next)
        XCTAssertEqual(state.currentAssetID, "a4")

        let undone = state.undo()
        XCTAssertEqual(undone, SortDecision(assetID: "a1", action: .keep, replaced: Verdict(action: .delete, isMarked: false)))
        XCTAssertEqual(state.currentAssetID, "a1", "Undo shows the photo it reverses")
        XCTAssertEqual(state.verdict(for: "a1"), Verdict(action: .delete, isMarked: false), "restored, as before")
        XCTAssertEqual(state.markedIDs, ["a2"])
        XCTAssertEqual(state.undo()?.assetID, "a2")
        XCTAssertNil(state.verdict(for: "a2"))
        XCTAssertEqual(state.currentAssetID, "a2")
        XCTAssertEqual(state.undo()?.assetID, "a1")
        XCTAssertEqual(state.sortedCount, 0)
        XCTAssertEqual(state.markedIDs, [])
        XCTAssertEqual(state, SortingState(assetIDs: ids), "every decision taken back")
    }

    /// A library change keeps the cursor on the photo on screen, or on the next one when that
    /// photo is gone; photos that leave take their decisions with them.
    func testReconcileKeepsTheCursorOnThePhotoOnScreen() {
        var state = SortingState(assetIDs: ids)
        state.apply(.delete)
        state.step(.next)
        state.apply(.keep)
        state.step(.next)
        state.step(.previous)
        state.step(.previous)
        XCTAssertEqual(state.currentAssetID, "a3")

        // a1 (decided, in the trash) and a2 (skipped) are deleted in Photos; a0 arrives.
        XCTAssertTrue(state.reconcile(albumAssetIDs: ["a0", "a3", "a4", "a5", "a6"]))
        XCTAssertEqual(state.assetIDs, ["a3", "a0", "a4", "a5", "a6"])
        XCTAssertEqual(state.currentAssetID, "a3")
        XCTAssertEqual(state.verdict(for: "a3"), Verdict(action: .keep, isMarked: false))
        XCTAssertEqual(state.markedIDs, [])
        XCTAssertEqual(state.history, [SortDecision(assetID: "a3", action: .keep)])

        // The photo on screen goes: the next one takes its place.
        XCTAssertTrue(state.reconcile(albumAssetIDs: ["a0", "a4", "a5", "a6"]))
        XCTAssertEqual(state.currentAssetID, "a0")
        XCTAssertEqual(state.sortedCount, 0)
        state.remove(["a0"])
        XCTAssertEqual(state.currentAssetID, "a4")
        XCTAssertEqual(state.position, 1)
    }

    /// Photos removed before the cursor (by Piq emptying the trash) keep the cursor on the same
    /// photo.
    func testRemovingPhotosBeforeTheCursorKeepsThePhotoOnScreen() {
        var state = SortingState(assetIDs: ids)
        state.apply(.delete)
        state.apply(.keep)
        state.apply(.delete)
        state.step(.next)
        XCTAssertEqual(state.currentAssetID, "a5")
        state.remove(["a1", "a3"])
        XCTAssertEqual(state.currentAssetID, "a5")
        XCTAssertEqual(state.assetIDs, ["a2", "a4", "a5", "a6"])
        XCTAssertEqual(state.history.map(\.assetID), ["a2"])
        XCTAssertEqual(state.resumePoint?.position, 2, "a4 was skipped")
    }

    /// Rebuilt from storage, anything that breaks the invariants is repaired: decisions of photos
    /// not in the list, a trash with an undecided or kept photo, a history that doesn't add up.
    func testRestoringFromPartsRepairsWhatDoesNotAddUp() {
        let state = SortingState(
            assetIDs: ids,
            currentIndex: 9,
            decisions: ["a1": .delete, "a3": .keep, "zz": .keep],
            markedIDs: ["a1", "a2", "a3"],
            history: [SortDecision(assetID: "a3", action: .delete)]
        )
        XCTAssertEqual(state.currentIndex, 6)
        XCTAssertEqual(state.decisions, ["a1": .delete, "a3": .keep])
        XCTAssertEqual(state.markedIDs, ["a1"])
        XCTAssertEqual(state.history, [SortDecision(assetID: "a1", action: .delete), SortDecision(assetID: "a3", action: .keep)], "rebuilt in session order")

        let consistent = [
            SortDecision(assetID: "a3", action: .delete),
            SortDecision(assetID: "a1", action: .delete),
            SortDecision(assetID: "a3", action: .keep, replaced: Verdict(action: .delete, isMarked: true)),
        ]
        let kept = SortingState(assetIDs: ids, currentIndex: 3, decisions: ["a1": .delete, "a3": .keep], markedIDs: ["a1"], history: consistent)
        XCTAssertEqual(kept.history, consistent, "a history that adds up stays as it is")
    }

    /// Thousands of random sessions worked on in every way: after each step the invariants hold,
    /// and the stored fields describe the state exactly.
    func testRandomWorkKeepsTheInvariantsAndRoundTripsThroughStorage() {
        var random = SeededGenerator(seed: 41)
        let pool = (0..<9).map { "p\($0)" }
        for trial in 0..<3_000 {
            var state = SortingState(assetIDs: Array(pool.prefix(Int.random(in: 0...9, using: &random))))
            for _ in 0..<Int.random(in: 0...24, using: &random) {
                state.randomStep(using: &random, pool: pool)
                let failure = state.brokenInvariant
                    ?? (Self.roundTripped(state) == state ? nil : "doesn't round-trip: \(Self.roundTripped(state))")
                if let failure {
                    XCTFail("Trial \(trial): \(failure) in \(state)")
                    return
                }
            }
        }
    }

    private static func roundTripped(_ state: SortingState) -> SortingState {
        let encoded = SortingSession.encode(state)
        return SortingSession.decode(assetIDs: state.assetIDs, decisions: encoded.decisions, cursor: state.currentIndex, undoLog: encoded.undoLog)
    }
}

extension SortingState {
    /// Decisions in any order: some photos decided, skipped, revisited and decided again, some
    /// undone, one restored.
    mutating func randomlyWorkedOn(using random: inout some RandomNumberGenerator) {
        for _ in 0..<Int.random(in: 0...(total * 2), using: &random) {
            switch Int.random(in: 0..<10, using: &random) {
            case 0..<5: apply(Bool.random(using: &random) ? .delete : .keep)
            case 5..<7: step(.next)
            case 7..<9: step(.previous)
            default: undo()
            }
        }
        if Bool.random(using: &random), let restored = markedIDs.randomElement(using: &random) {
            unmark([restored])
        }
    }

    /// One random change of any kind, library changes included.
    mutating func randomStep(using random: inout some RandomNumberGenerator, pool: [String]) {
        switch Int.random(in: 0..<14, using: &random) {
        case 0..<4: apply(Bool.random(using: &random) ? .delete : .keep)
        case 4..<6: step(.next)
        case 6..<8: step(.previous)
        case 8: undo()
        case 9: goToFirstUnsorted()
        case 10: if let id = markedIDs.randomElement(using: &random) { unmark([id]) }
        case 11: if let id = assetIDs.randomElement(using: &random) { remove([id]) }
        case 12: reconcile(albumAssetIDs: Array(pool.shuffled(using: &random).prefix(Int.random(in: 0...pool.count, using: &random))), keepingSortedPhotos: Bool.random(using: &random))
        default: reconcile(albumAssetIDs: assetIDs + ["n\(Int.random(in: 0..<1_000, using: &random))"])
        }
    }

    /// What breaks the engine's invariants, if anything (see `SortingState`).
    var brokenInvariant: String? {
        let present = Set(assetIDs)
        if present.count != assetIDs.count { return "duplicate photos" }
        if currentIndex < 0 || currentIndex > total { return "cursor out of range" }
        if !decisions.keys.allSatisfy(present.contains) { return "a decision of a photo not in the session" }
        if !markedIDs.allSatisfy({ decisions[$0] == .delete }) { return "a photo in the trash not decided delete" }
        var replayed: [String: SwipeAction] = [:]
        for decision in history {
            if decision.replaced?.action != replayed[decision.assetID] { return "history entry \(decision) doesn't follow the one before" }
            replayed[decision.assetID] = decision.action
        }
        return replayed == decisions ? nil : "history doesn't add up to the decisions"
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
