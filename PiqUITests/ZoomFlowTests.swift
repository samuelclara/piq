import XCTest

/// Pinch-to-zoom with real gestures, on the mock library: on the sorting screen (pinch and
/// double-tap in and out, a drag that moves the zoomed photo instead of deciding, Delete still
/// deciding while zoomed) and in Review's full-screen preview (a drag down moves the zoomed photo
/// instead of closing the preview). The photo's VoiceOver value says "Zoomed in" while it is.
/// The "Iceland 2026" scenario opens at 38 of 400 with 4 photos marked.
@MainActor
final class ZoomFlowTests: ExperienceTestCase {
    private enum ZoomID {
        static let previewPhoto = "review.previewPhoto"
    }

    func testPinchingZoomsAndADragThenMovesThePhotoInsteadOfDeciding() {
        let app = launch(scenario: "sorting")
        expectSorting(app, position: 38, total: 400, marked: 4)
        let photo = element(ID.photo, in: app)
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        expectZoomed(false, photo)

        photo.pinch(withScale: 3, velocity: 2)
        expectZoomed(true, photo)
        shoot("zoom-sorting-pinched", app)

        // Zoomed in, a swipe moves the photo: nothing is decided.
        photo.swipeLeft()
        photo.swipeRight()
        Thread.sleep(forTimeInterval: 0.6)
        expectSorting(app, position: 38, total: 400, marked: 4)
        expectZoomed(true, photo)

        // Pinching back out past the whole photo settles at it, and a swipe decides again.
        photo.pinch(withScale: 0.2, velocity: -2)
        expectZoomed(false, photo)
        photo.swipeLeft()
        expectToast("Marked for deletion", in: app)
        expectSorting(app, position: 39, total: 400, marked: 5)
    }

    func testDoubleTapZoomsInAndOut() {
        let app = launch(scenario: "sorting")
        expectSorting(app, position: 38, total: 400, marked: 4)
        let photo = element(ID.photo, in: app)
        XCTAssertTrue(photo.waitForExistence(timeout: 5))

        photo.doubleTap()
        expectZoomed(true, photo)
        photo.doubleTap()
        expectZoomed(false, photo)
        photo.swipeRight()
        expectSorting(app, position: 39, total: 400, marked: 4)
    }

    /// The buttons and keys decide whatever the zoom; the next photo comes up whole.
    func testDeletingAZoomedPhotoShowsTheNextOneWhole() {
        let app = launch(scenario: "sorting")
        expectSorting(app, position: 38, total: 400, marked: 4)
        let photo = element(ID.photo, in: app)
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        photo.pinch(withScale: 2.5, velocity: 2)
        expectZoomed(true, photo)

        app.buttons[ID.delete].tap()
        expectToast("Marked for deletion", in: app)
        expectSorting(app, position: 39, total: 400, marked: 5)
        expectZoomed(false, photo)

        photo.doubleTap()
        expectZoomed(true, photo)
        wakeKeyboard(app)
        press(.rightArrow, in: app)
        expectSorting(app, position: 40, total: 400, marked: 5)
        expectZoomed(false, photo)

        // Undo brings the kept photo back whole too.
        app.buttons[ID.undo].tap()
        expectSorting(app, position: 39, total: 400, marked: 5)
        expectZoomed(false, photo)
    }

    func testThePreviewZoomsAndADragDownThenMovesThePhoto() {
        let app = launch(scenario: "review")
        let tile = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'review.tile.'")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        tile.press(forDuration: 0.5)
        let close = app.buttons[ID.closePreview]
        XCTAssertTrue(close.waitForExistence(timeout: 3), "A long press opens the preview")
        let photo = element(ZoomID.previewPhoto, in: app)
        XCTAssertTrue(photo.waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 0.8)
        expectZoomed(false, photo)

        photo.pinch(withScale: 3, velocity: 2)
        expectZoomed(true, photo)
        shoot("zoom-preview-pinched", app)

        // Zoomed in, a drag down moves the photo and the preview stays.
        dragDown(app)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(close.exists, "the preview stays open")
        expectZoomed(true, photo)

        photo.doubleTap()
        expectZoomed(false, photo)
        // Whole again, a drag down closes it.
        dragDown(app)
        XCTAssertTrue(close.waitForNonExistence(timeout: 4), "a drag down closes the whole photo")
    }

    // MARK: Helpers

    private func dragDown(_ app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 360)), withVelocity: .default, thenHoldForDuration: 0)
    }

    private func expectZoomed(_ isZoomed: Bool, _ photo: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate { _, _ in
            guard photo.exists else { return false }
            let value = photo.value as? String ?? ""
            return value.hasPrefix("Zoomed in") == isZoomed
        }
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 4)
        XCTAssertEqual(result, .completed, "Expected the photo \(isZoomed ? "zoomed in" : "whole"), its value is “\(photo.exists ? (photo.value as? String ?? "") : "<missing>")”", file: file, line: line)
    }
}
