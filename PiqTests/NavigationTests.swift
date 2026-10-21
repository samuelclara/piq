import SwiftData
import SwiftUI
import XCTest
@testable import Piq

/// Previous and Next on the sorting screen: moves that decide nothing, are saved at once and
/// aren't undoable; deciding a photo again replaces its decision; resuming and "Continue sorting"
/// pick up at the first unsorted photo; the deck's slides, the photo's VoiceOver actions and label,
/// and the keys.
@MainActor
final class NavigationTests: XCTestCase {
    // MARK: Session

    func testAMoveIsSavedAtOnceAndIsNotUndoable() throws {
        let fixture = SessionFixture()
        let session = fixture.session
        let ids = fixture.ids
        session.decide(.keep)

        XCTAssertTrue(session.step(.next))
        XCTAssertTrue(session.step(.next))
        XCTAssertTrue(session.step(.previous))
        XCTAssertEqual(session.lastChange, .moved(.previous))
        XCTAssertEqual(session.state.currentAssetID, ids[2])
        XCTAssertEqual(session.state.sortedCount, 1, "moves decide nothing")
        XCTAssertFalse(fixture.container.mainContext.hasChanges, "saved")
        XCTAssertEqual(fixture.record.cursor, 2)
        assertRecord(fixture.record, matches: session.state)
        XCTAssertEqual(try savedSessions(in: fixture.container).first?.state, session.state)

        // Undo takes back the decision, not the moves, and shows its photo.
        XCTAssertEqual(session.undo(), SortDecision(assetID: ids[0], action: .keep))
        XCTAssertEqual(session.state.currentAssetID, ids[0])
        XCTAssertFalse(session.state.canUndo)
        XCTAssertFalse(session.step(.previous), "nothing before the first photo")
        XCTAssertEqual(session.lastChange, .undone(SortDecision(assetID: ids[0], action: .keep)))
        assertRecord(fixture.record, matches: session.state)
    }

    func testDecidingARevisitedPhotoReplacesItsDecisionAndUndoPutsItBack() throws {
        let fixture = SessionFixture()
        let session = fixture.session
        let ids = fixture.ids
        session.sortNext([.keep, .delete, .keep])
        session.step(.previous)
        session.step(.previous)
        XCTAssertEqual(session.state.verdict(for: ids[1]), Verdict(action: .delete, isMarked: true))

        let replaced = try XCTUnwrap(session.decide(.keep))
        XCTAssertEqual(replaced, SortDecision(assetID: ids[1], action: .keep, replaced: Verdict(action: .delete, isMarked: true)))
        XCTAssertEqual(session.state.markedCount, 0, "out of the trash")
        XCTAssertEqual(session.state.sortedCount, 3)
        XCTAssertEqual(session.state.currentAssetID, ids[2], "moves on, like any decision")
        assertRecord(fixture.record, matches: session.state)

        session.step(.next)
        session.step(.next)
        XCTAssertEqual(session.undo(), replaced)
        XCTAssertEqual(session.state.currentAssetID, ids[1], "Undo shows the photo it reverses")
        XCTAssertEqual(session.state.verdict(for: ids[1]), Verdict(action: .delete, isMarked: true), "marked again")
        assertRecord(fixture.record, matches: session.state)
        XCTAssertEqual(try savedSessions(in: fixture.container).first?.state, session.state)
    }

    func testAPhotoRestoredInReviewAndDecidedAgainComesBackRestoredOnUndo() throws {
        let fixture = SessionFixture()
        let session = fixture.session
        let ids = fixture.ids
        session.sortNext([.delete, .keep])
        session.restore([ids[0]])
        session.step(.previous)
        session.step(.previous)
        XCTAssertEqual(session.state.verdict(for: ids[0]), Verdict(action: .delete, isMarked: false), "shows as kept")
        session.decide(.delete)
        XCTAssertEqual(session.state.markedInOrder, [ids[0]])
        session.undo()
        XCTAssertEqual(session.state.verdict(for: ids[0]), Verdict(action: .delete, isMarked: false))
        XCTAssertEqual(session.state.markedCount, 0)
        assertRecord(fixture.record, matches: session.state)
    }

    // MARK: Resuming

    /// "Resume · 2 of 36" names the first unsorted photo, and opening the album goes there,
    /// wherever the cursor was. A finished session with a trash still says "Review · …".
    func testResumingPicksUpAtTheFirstUnsortedPhoto() async throws {
        let (app, _) = try await startedApp()
        let lisbon = try album("Weekend in Lisbon", in: app)
        await app.openAlbum(lisbon)
        let session = try XCTUnwrap(app.activeSession)
        let ids = session.state.assetIDs
        session.decide(.keep)
        session.step(.next)
        session.sortNext([.delete, .keep, .keep])
        XCTAssertEqual(session.state.currentAssetID, ids[5])
        app.returnToAlbums()

        let resume = app.resumePoint(for: lisbon.id)
        XCTAssertEqual(resume, ResumePoint(position: 2, total: 36, markedCount: 1, isComplete: false))
        XCTAssertEqual(PickerBottomBar.startTitle(for: lisbon, resume: resume), "Resume · 2 of 36")
        XCTAssertEqual(session.record.resumePoint, resume, "the saved session says the same")

        await app.openAlbum(lisbon)
        XCTAssertEqual(app.path, [.sorting(albumID: lisbon.id)])
        XCTAssertEqual(session.state.currentAssetID, ids[1])
        XCTAssertEqual(session.record.cursor, 1, "saved")

        // Everything decided, the trash not emptied: Review, as before.
        while !session.state.isComplete {
            session.goToFirstUnsorted()
            session.decide(.keep)
        }
        app.returnToAlbums()
        XCTAssertEqual(PickerBottomBar.startTitle(for: lisbon, resume: app.resumePoint(for: lisbon.id)), "Review · 1 photo marked")
    }

    /// From Review, "Continue sorting" goes to the first unsorted photo too.
    func testContinueSortingFromReviewGoesToTheFirstUnsortedPhoto() async throws {
        let (app, _) = try await startedApp()
        await app.openAlbum(try album("Family", in: app))
        let session = try XCTUnwrap(app.activeSession)
        let ids = session.state.assetIDs
        session.step(.next)
        session.sortNext([.keep, .delete])
        app.showReview()
        XCTAssertEqual(app.path.last, .review(albumID: session.albumID))
        XCTAssertFalse(session.state.isComplete)
        XCTAssertEqual(ReviewCopy.summary(sorted: session.state.sortedCount, total: session.state.total), "2 of 18 sorted so far. Nothing is deleted until you empty the trash.")

        app.continueSorting()
        XCTAssertEqual(app.path, [.sorting(albumID: session.albumID)])
        XCTAssertEqual(session.state.currentAssetID, ids[0], "the photo skipped first")
    }

    // MARK: The deck

    /// Next: the session moves at once, the card slides off flat (a departure with no decision),
    /// and its images are kept so Previous brings it back sharp. Memory stays at the window (the
    /// current photo and the next three) plus that one photo.
    func testNextSlidesTheCardOffAndKeepsItForPrevious() async throws {
        let (app, session) = PreviewSupport.session(.sorting)
        let deck = try await showStage(of: session, in: app)
        let leaving = try XCTUnwrap(session.state.currentAssetID)
        try await waitUntilSharp(leaving, in: deck)
        let slot = deck.slot(for: leaving)

        deck.step(.next)
        XCTAssertEqual(session.state.position, 39)
        XCTAssertEqual(session.state.sortedCount, 37, "nothing decided")
        let departure = try XCTUnwrap(deck.departures.first)
        XCTAssertEqual(departure.id, leaving)
        XCTAssertNil(departure.action, "it slides off flat and untinted")
        XCTAssertNil(deck.pendingDeparture, "nothing to commit")
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertTrue(deck.departures.isEmpty, "gone once off the stage")
        XCTAssertEqual(deck.loader.slots.count, 4, "the window: the photo on screen and the next three")
        XCTAssertNil(deck.loader.slot(for: leaving), "the loader let it go")
        XCTAssertTrue(deck.lastDeparted === slot, "kept for Previous")

        deck.step(.previous)
        XCTAssertEqual(session.state.currentAssetID, leaving)
        XCTAssertEqual(deck.returning, SwipeDeck.Return(id: leaving, direction: .left, tilts: false), "slides in from the left, flat")
        XCTAssertEqual(deck.slot(for: leaving)?.isSharp, true, "back sharp at once")
    }

    /// A decision, then Next: the one photo kept for later stays the decided one, so Undo still
    /// brings it back sharp at once (as before Previous and Next existed). Memory stays at the
    /// window plus that one photo.
    func testUndoAfterADecisionAndNextComesBackSharp() async throws {
        let (app, session) = PreviewSupport.session(.sorting)
        let deck = try await showStage(of: session, in: app)
        let decided = try XCTUnwrap(session.state.currentAssetID)
        try await waitUntilSharp(decided, in: deck)
        deck.decideNow(.keep)
        let skipped = try XCTUnwrap(session.state.currentAssetID)
        try await waitUntilSharp(skipped, in: deck)

        deck.step(.next)
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(deck.lastDeparted?.id, decided, "Next leaves the photo Undo returns to")
        XCTAssertEqual(deck.loader.slots.count, 4)
        deck.undo()
        XCTAssertEqual(session.state.currentAssetID, decided)
        XCTAssertEqual(deck.slot(for: decided)?.isSharp, true, "back sharp at once")

        // Back on it, the loader has it again and the kept copy goes: Next keeps the photo it
        // leaves, for Previous, again.
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertNil(deck.lastDeparted)
        deck.step(.next)
        XCTAssertEqual(deck.lastDeparted?.id, decided)
    }

    /// Previous while a decided card is still in the air: the decision lands first, then the
    /// session goes back to that photo, which shows its new decision.
    func testAMoveCommitsACardStillInTheAirFirst() async throws {
        let (app, session) = PreviewSupport.session(.sorting)
        let deck = try await showStage(of: session, in: app)
        let id = try XCTUnwrap(session.state.currentAssetID)
        deck.decide(.delete)
        XCTAssertNotNil(deck.pendingDeparture)
        XCTAssertTrue(deck.canGoBack)

        deck.step(.previous)
        XCTAssertNil(deck.pendingDeparture)
        XCTAssertEqual(session.state.currentAssetID, id)
        XCTAssertEqual(session.state.verdict(for: id), Verdict(action: .delete, isMarked: true))
        XCTAssertEqual(session.state.markedCount, 5)
    }

    /// Next on the last photo, with photos skipped, goes on to Review, which offers to continue.
    func testNextPastTheLastPhotoOpensReview() async throws {
        let app = PreviewSupport.appModel(.albums)
        await app.openAlbum(try album("Family", in: app))
        let session = try XCTUnwrap(app.activeSession)
        session.decide(.delete)
        while session.state.position < session.state.total {
            session.step(.next)
        }
        let deck = try await showStage(of: session, in: app)
        XCTAssertTrue(deck.canGoForward, "Next on the last photo leads on")
        deck.step(.next)
        XCTAssertNil(session.state.currentAssetID)
        XCTAssertFalse(deck.canGoForward)
        XCTAssertEqual(app.path.last, .review(albumID: session.albumID))
        XCTAssertFalse(session.state.isComplete, "17 photos skipped: Review's back button says Continue sorting")
    }

    /// Moves do nothing while Review is on top of sorting (the screen underneath stays alive).
    func testMovesDoNothingUnderReview() async throws {
        let (app, session) = PreviewSupport.session(.reviewPartial)
        let deck = SwipeDeck(session: session, app: app)
        let before = session.state
        deck.step(.next)
        deck.step(.previous)
        XCTAssertEqual(session.state, before)
    }

    // MARK: VoiceOver

    /// The photo is one element with Delete and Keep, then Previous photo and Next photo while
    /// there is a photo to go to; its label says a revisited photo's decision. (The UI tests read
    /// the label off the screen; XCUITest can't run custom actions, so they are checked here.)
    func testThePhotosVoiceOverActionsAndLabel() async throws {
        let (app, session) = PreviewSupport.session(.sorting)
        let deck = try await showStage(of: session, in: app)
        func names() -> [String] {
            PhotoAccessibilityAction.available(canGoBack: deck.canGoBack, canGoForward: deck.canGoForward).map(\.name)
        }
        XCTAssertEqual(names(), ["Delete", "Keep", "Previous photo", "Next photo"])

        // What the action reads out, built as it builds it, right after the move: the photos
        // Previous lands on have left the loader, and the label still has their details.
        deck.step(.previous)
        var spoken = await SortingStage.currentPhotoLabel(in: deck)
        var label = try XCTUnwrap(spoken)
        XCTAssertTrue(label.hasPrefix("Photo 37 of 400, IMG_4437.HEIC, "), label)
        XCTAssertTrue(label.hasSuffix(", kept"), label)
        deck.step(.previous)
        spoken = await SortingStage.currentPhotoLabel(in: deck)
        label = try XCTUnwrap(spoken)
        XCTAssertTrue(label.hasPrefix("Photo 36 of 400, IMG_4436.HEIC, "), label)
        XCTAssertEqual(label.components(separatedBy: ", ").count, 4, "position, filename, time, decision: \(label)")
        XCTAssertEqual(
            SortingStage.photoLabel(position: 28, total: 400, metadata: nil, verdict: Verdict(action: .delete, isMarked: true)),
            "Photo 28 of 400, marked for deletion"
        )
        XCTAssertEqual(SortingStage.photoLabel(position: 38, total: 400, metadata: nil, verdict: nil), "Photo 38 of 400", "unsorted: no decision")

        // At either end, the move that has nowhere to go isn't offered.
        while session.step(.previous) {}
        XCTAssertEqual(names(), ["Delete", "Keep", "Next photo"])
        while session.step(.next) {}
        XCTAssertEqual(names(), ["Delete", "Keep", "Previous photo"])
    }

    /// Where Previous and Next go: by the counter only while the album title keeps its room
    /// beside them at the current text size, else in the row under the photo.
    func testTheChevronsLeaveTheTopBarBeforeTheTitleTruncates() {
        let defaultScale = SortingBarFit.textScale(at: .large)
        let largest = SortingBarFit.textScale(at: .xxLarge)
        XCTAssertEqual(defaultScale, 1)
        XCTAssertGreaterThan(largest, 1.15)
        func holds(_ width: CGFloat, _ scale: CGFloat, controls: CGFloat = 0) -> Bool {
            SortingBarFit.holdsStepButtons(width: width, textScale: scale, leadingInset: Metrics.topBarLeadingInset(clearing: controls))
        }
        XCTAssertTrue(holds(1194, defaultScale))
        XCTAssertTrue(holds(834, defaultScale))
        XCTAssertTrue(holds(520, defaultScale), "as designed at the default size")
        XCTAssertFalse(holds(519, defaultScale))
        XCTAssertFalse(holds(520, largest), "the title would truncate")
        XCTAssertFalse(holds(540, largest))
        XCTAssertTrue(holds(560, largest), "the title keeps its room, scaled")
        XCTAssertTrue(holds(678, largest))
        XCTAssertTrue(holds(1194, largest))
        XCTAssertFalse(holds(520, defaultScale, controls: 90), "window controls narrow the center too")
    }

    // MARK: Keys

    /// ⌘[ and ⌘] go to the Previous and Next buttons' shortcuts: the photo's key handler leaves
    /// them alone, and ← and → still decide.
    func testPreviousAndNextKeysAreTheButtonsShortcuts() {
        XCTAssertEqual(PhotoStep.previous.keyboardShortcut, KeyboardShortcut("[", modifiers: .command))
        XCTAssertEqual(PhotoStep.next.keyboardShortcut, KeyboardShortcut("]", modifiers: .command))
        XCTAssertEqual(SortingKeyResponse(key: "[", modifiers: .command, phase: .down), .ignore)
        XCTAssertEqual(SortingKeyResponse(key: "]", modifiers: .command, phase: .down), .ignore)
        XCTAssertEqual(SortingKeyResponse(key: .leftArrow, modifiers: [], phase: .down), .decide(.delete))
        XCTAssertEqual(SortingKeyResponse(key: .rightArrow, modifiers: [], phase: .down), .decide(.keep))
    }

    // MARK: Saving

    /// A move saves the cursor only: as cheap as a decision, 29,000 photos into a 30,000-photo
    /// session. (A loose budget: it catches a move that rewrites the decisions or the list.)
    func testAMoveCostsLittleToSaveLateInALongSession() async throws {
        let url = URL.temporaryDirectory.appending(path: "PiqMoveCost-\(UUID().uuidString).store")
        defer { PersistenceMigrationTests.removeStore(at: url) }
        let ids = (0..<30_000).map { _ in UUID().uuidString + "/L0/001" }
        let container = try SessionStore.makeContainer(ModelConfiguration(url: url, cloudKitDatabase: .none))
        let store = SessionStore(context: container.mainContext)
        let record = store.insertSession(albumID: "recents", title: "Recents", assetIDs: ids)
        var state = record.state
        for index in 0..<29_000 {
            state.apply(index % 8 == 3 ? .delete : .keep)
        }
        record.state = state
        store.save()
        let session = SessionController(record: record, store: store, library: StubPhotoLibrary())

        let clock = ContinuousClock()
        var durations: [Duration] = []
        for index in 0..<120 {
            durations.append(clock.measure { session.step(index % 3 == 2 ? .previous : .next) })
            XCTAssertFalse(container.mainContext.hasChanges)
        }
        let median = durations.sorted()[durations.count / 2]
        print("A move 29,000 photos into a 30,000-photo session: median \(median), max \(durations.max() ?? .zero)")
        XCTAssertLessThan(median, .milliseconds(3))
        XCTAssertEqual(try savedSessions(in: container).first?.state, session.state)
    }

    /// Quit and relaunch: the cursor and every decision come back as they were; opening the
    /// album then resumes at the first unsorted photo.
    func testARelaunchKeepsTheCursorAndTheDecisions() async throws {
        let url = URL.temporaryDirectory.appending(path: "PiqNavRelaunch-\(UUID().uuidString).store")
        defer { PersistenceMigrationTests.removeStore(at: url) }
        let library = MockPhotoLibrary()
        let lisbonIDs = library.photoIDs(inAlbum: MockPhotoLibrary.lisbonAlbumID)
        var before = SortingState(assetIDs: [])
        do {
            let app = try await launch(library, storeURL: url)
            await app.openAlbum(try album("Weekend in Lisbon", in: app))
            let session = try XCTUnwrap(app.activeSession)
            session.decide(.keep)
            session.step(.next)
            session.decide(.delete)
            session.step(.next)
            session.step(.previous)
            session.step(.previous)
            before = session.state
            XCTAssertEqual(before.currentAssetID, lisbonIDs[2])
        }

        let app = try await launch(library, storeURL: url)
        let record = try XCTUnwrap(app.store.session(albumID: MockPhotoLibrary.lisbonAlbumID))
        XCTAssertEqual(record.cursor, 2)
        XCTAssertEqual(record.state, before)
        XCTAssertEqual(app.resumePoint(for: MockPhotoLibrary.lisbonAlbumID), ResumePoint(position: 2, total: 36, markedCount: 1, isComplete: false))
        await app.openAlbum(try album("Weekend in Lisbon", in: app))
        XCTAssertEqual(app.activeSession?.state.currentAssetID, lisbonIDs[1])
        XCTAssertEqual(app.activeSession?.undo()?.assetID, lisbonIDs[2], "the undo history too")
    }

    // MARK: Helpers

    private func launch(_ library: MockPhotoLibrary, storeURL url: URL) async throws -> AppModel {
        let container = try SessionStore.makeContainer(ModelConfiguration(url: url, cloudKitDatabase: .none))
        let app = AppModel(library: library, images: SpyImageSource(), container: container)
        await app.start()
        return app
    }

    /// A deck for `session`, its stage on screen so its slides animate as in the app.
    private func showStage(of session: SessionController, in app: AppModel) async throws -> SwipeDeck {
        let deck = SwipeDeck(session: session, app: app)
        let window = try makeReviewTestWindow(width: 1194) {
            NavigationStageHost(deck: deck).environment(app)
        }
        addTeardownBlock { @MainActor in window.isHidden = true }
        deck.appear()
        try await Task.sleep(for: .milliseconds(500))
        return deck
    }

    private func waitUntilSharp(_ id: String, in deck: SwipeDeck) async throws {
        for _ in 0..<50 where deck.slot(for: id)?.isSharp != true {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(deck.slot(for: id)?.isSharp, true)
    }
}

/// The sorting stage alone.
private struct NavigationStageHost: View {
    let deck: SwipeDeck
    @FocusState private var hasKeyFocus: Bool

    var body: some View {
        SortingStage(deck: deck, keyFocus: $hasKeyFocus, onKeyPress: { _ in .ignored }, onAccessibilityDecision: { _ in }, onAccessibilityStep: { deck.step($0) })
            // As the sorting screen does: the loader follows the cursor.
            .onChange(of: deck.session.state.window(lookahead: PhotoWindowLoader.lookahead)) { _, window in
                deck.show(window)
            }
    }
}
