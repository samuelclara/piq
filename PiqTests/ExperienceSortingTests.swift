import SwiftUI
import XCTest
@testable import Piq

/// The sorting screen's keys and the moment a decision lands: one key press decides one photo,
/// and a card still in the air when the app closes the screen counts without a word.
@MainActor
final class ExperienceSortingTests: XCTestCase {
    // MARK: Keys

    func testArrowKeysDecideOncePerPress() {
        XCTAssertEqual(SortingKeyResponse(key: .leftArrow, modifiers: [], phase: .down), .decide(.delete))
        XCTAssertEqual(SortingKeyResponse(key: .rightArrow, modifiers: [], phase: .down), .decide(.keep))
        XCTAssertEqual(SortingKeyResponse(key: .leftArrow, modifiers: [], phase: .repeat), .swallow, "a held ← marks one photo, not one per repeat")
        XCTAssertEqual(SortingKeyResponse(key: .rightArrow, modifiers: [], phase: .repeat), .swallow)
        XCTAssertEqual(SortingKeyResponse(key: .rightArrow, modifiers: [], phase: .up), .swallow)
    }

    func testOtherKeysAreLeftToTheApp() {
        XCTAssertEqual(SortingKeyResponse(key: .leftArrow, modifiers: .command, phase: .down), .ignore)
        XCTAssertEqual(SortingKeyResponse(key: .rightArrow, modifiers: .shift, phase: .down), .ignore)
        XCTAssertEqual(SortingKeyResponse(key: "z", modifiers: .command, phase: .down), .ignore, "⌘Z is Undo's")
        XCTAssertEqual(SortingKeyResponse(key: .upArrow, modifiers: [], phase: .down), .ignore)
        XCTAssertEqual(SortingKeyResponse(key: .leftArrow, modifiers: .capsLock, phase: .down), .decide(.delete), "Caps Lock isn't a modifier")
        XCTAssertEqual(SortingKeyResponse(key: .rightArrow, modifiers: .numericPad, phase: .down), .decide(.keep), "nor is the numeric pad flag")
    }

    // MARK: Landing

    func testADeletionOnScreenIsConfirmed() async throws {
        let (app, session) = PreviewSupport.session(.sorting)
        let deck = try await showStage(of: session, in: app)
        deck.decide(.delete)
        XCTAssertNotNil(deck.pendingDeparture, "the card is in the air")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(deck.pendingDeparture)
        XCTAssertEqual(session.state.markedCount, 5)
        XCTAssertEqual(app.toasts.current?.message, "Marked for deletion")
    }

    /// The app closes the sorting screen (Photos access lost, the album deleted) and explains
    /// why while a deleted photo is still flying off: the photo counts, the explanation stays.
    func testACardLandingAfterTheAppClosedTheScreenIsQuiet() async throws {
        let (app, session) = PreviewSupport.session(.sorting)
        let deck = try await showStage(of: session, in: app)
        deck.decide(.delete)
        XCTAssertNotNil(deck.pendingDeparture)
        closeWithExplanation(app)

        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(deck.pendingDeparture, "it landed")
        XCTAssertEqual(session.state.markedCount, 5, "the swipe counts")
        XCTAssertEqual(app.toasts.current?.message, Self.explanation)
    }

    /// The same, when the screen goes away before the card lands.
    func testACardInTheAirWhenTheScreenGoesAwayIsQuiet() async throws {
        let (app, session) = PreviewSupport.session(.sorting)
        let deck = try await showStage(of: session, in: app)
        deck.decide(.delete)
        closeWithExplanation(app)
        deck.disappear()

        XCTAssertEqual(session.state.markedCount, 5)
        XCTAssertEqual(app.toasts.current?.message, Self.explanation)
    }

    /// The last photo landing after the screen closed doesn't open Review over the albums.
    func testTheLastPhotoLandingAfterTheScreenClosedStaysOnTheAlbums() async throws {
        let app = PreviewSupport.appModel(.albums)
        let family = try XCTUnwrap(app.albums.first { $0.title == "Family" })
        await app.openAlbum(family)
        let session = try XCTUnwrap(app.activeSession)
        while session.state.remainingCount > 1 {
            session.decide(.keep)
        }
        let deck = try await showStage(of: session, in: app)
        deck.decide(.keep)
        app.returnToAlbums()

        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(session.state.isComplete)
        XCTAssertEqual(app.path, [])
    }

    // MARK: Helpers

    private static let explanation = "Iceland 2026 is no longer in Photos"

    /// What `AppModel` does when the open album goes away: back to the albums, with a toast.
    private func closeWithExplanation(_ app: AppModel) {
        app.returnToAlbums()
        app.toasts.show(Self.explanation, systemImage: "exclamationmark.circle")
    }

    /// A deck for `session`, its stage on screen so its flights animate as in the app.
    private func showStage(of session: SessionController, in app: AppModel) async throws -> SwipeDeck {
        let deck = SwipeDeck(session: session, app: app)
        let window = try makeReviewTestWindow(width: 1194) {
            StageHost(deck: deck).environment(app)
        }
        addTeardownBlock { @MainActor in window.isHidden = true }
        deck.appear()
        try await Task.sleep(for: .milliseconds(500))
        return deck
    }
}

/// The sorting stage alone.
private struct StageHost: View {
    let deck: SwipeDeck
    @FocusState private var hasKeyFocus: Bool

    var body: some View {
        SortingStage(deck: deck, keyFocus: $hasKeyFocus, onKeyPress: { _ in .ignored }, onAccessibilityDecision: { _ in })
    }
}
