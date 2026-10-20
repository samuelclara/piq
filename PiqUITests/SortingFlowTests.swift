import XCTest

/// Drives the sorting screen with real input (swipes on the photo, the Delete and Keep pills,
/// the arrow keys and ⌘Z) and checks the counter, the marked badge and the toast. Runs on the
/// mock library's "Iceland 2026" session, which opens at 38 of 400 with 4 photos marked.
@MainActor
final class SortingFlowTests: XCTestCase {
    private enum ID {
        static let back = "sorting.back"
        static let counter = "sorting.counter"
        static let undo = "sorting.undo"
        static let review = "sorting.review"
        static let photo = "sorting.photo"
        static let delete = "sorting.delete"
        static let keep = "sorting.keep"
        static let toast = "toast"
        static let reviewBack = "review.back"
    }

    func testSwipesButtonsKeysAndUndo() {
        let app = launchSorting()
        expect(app, position: 38, marked: 4)
        XCTAssertTrue(app.buttons[ID.back].exists)
        // "Photo 38 of 400, IMG_4438.HEIC, <capture time>": one element for VoiceOver.
        XCTAssertTrue(photo(in: app).label.hasPrefix("Photo 38 of 400, IMG_4438.HEIC, "), "Photo label: \(photo(in: app).label)")

        photo(in: app).swipeLeft()
        expect(app, position: 39, marked: 5)
        let toast = app.descendants(matching: .any)[ID.toast]
        XCTAssertTrue(toast.waitForExistence(timeout: 2), "Deleting shows a toast")
        XCTAssertTrue(toast.label.contains("Marked for deletion"), "Toast says \(toast.label)")

        app.buttons[ID.keep].tap()
        expect(app, position: 40, marked: 5)

        app.typeKey(.leftArrow, modifierFlags: [])
        expect(app, position: 41, marked: 6)

        app.typeKey(.rightArrow, modifierFlags: [])
        expect(app, position: 42, marked: 6)

        app.typeKey("z", modifierFlags: .command)
        expect(app, position: 41, marked: 6)

        app.typeKey("z", modifierFlags: .command)
        expect(app, position: 40, marked: 5)

        app.buttons[ID.undo].tap()
        expect(app, position: 39, marked: 5)

        photo(in: app).swipeRight()
        expect(app, position: 40, marked: 5)

        app.buttons[ID.delete].tap()
        expect(app, position: 41, marked: 6)
    }

    func testShortDragSpringsBackAndLongDragCommits() {
        let app = launchSorting()
        let center = photo(in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))

        // Short of the 140pt threshold: the photo springs back and nothing is decided.
        center.press(forDuration: 0.1, thenDragTo: center.withOffset(CGVector(dx: -90, dy: 10)), withVelocity: .slow, thenHoldForDuration: 0.2)
        Thread.sleep(forTimeInterval: 0.8)
        expect(app, position: 38, marked: 4)

        // A slow drag past it, released there, keeps the photo.
        center.press(forDuration: 0.1, thenDragTo: center.withOffset(CGVector(dx: 220, dy: -20)), withVelocity: .slow, thenHoldForDuration: 0.2)
        expect(app, position: 39, marked: 4)
    }

    /// Undoing a delete takes its "Marked for deletion" toast down instead of leaving it up for
    /// the rest of its 2.2 seconds.
    func testUndoTakesDownTheDeleteToast() {
        let app = launchSorting()
        let toast = app.descendants(matching: .any)[ID.toast]
        app.buttons[ID.delete].tap()
        XCTAssertTrue(toast.waitForExistence(timeout: 2), "Deleting shows a toast")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(toast.waitForNonExistence(timeout: 1), "Undo takes the toast down")
        expect(app, position: 38, marked: 4)
    }

    func testUndoStopsAtTheFirstPhoto() {
        let app = launchSorting()
        let undo = app.buttons[ID.undo]
        for _ in 0..<37 {
            app.typeKey("z", modifierFlags: .command)
        }
        expect(app, position: 1, marked: 0)
        XCTAssertFalse(undo.isEnabled, "Nothing left to undo")

        // Nothing happens when there is nothing to undo.
        app.typeKey("z", modifierFlags: .command)
        undo.tap()
        expect(app, position: 1, marked: 0)
    }

    /// Review is pushed on top of sorting, which stays alive underneath: the sorting keys must
    /// not reach the session from there, and back on sorting they work from the first press.
    func testArrowKeysDoNothingUnderReview() throws {
        let app = launchSorting()
        let back = app.buttons[ID.reviewBack]
        app.buttons[ID.review].tap()
        guard back.waitForExistence(timeout: 3) else {
            throw XCTSkip("The Review screen has no back button yet")
        }
        pressSortingKeys(app)
        back.tap()
        XCTAssertTrue(back.waitForNonExistence(timeout: 3))
        expect(app, position: 38, marked: 4)
        app.typeKey(.leftArrow, modifierFlags: [])
        expect(app, position: 39, marked: 5)

        // Once more, with ⌘Z as the first key back.
        app.buttons[ID.review].tap()
        XCTAssertTrue(back.waitForExistence(timeout: 3))
        pressSortingKeys(app)
        back.tap()
        XCTAssertTrue(back.waitForNonExistence(timeout: 3))
        expect(app, position: 39, marked: 5)
        app.typeKey("z", modifierFlags: .command)
        expect(app, position: 38, marked: 4)
    }

    // MARK: Helpers

    private func launchSorting() -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-PiqMockLibrary", "-PiqMockAccess", "authorized", "-PiqMockScenario", "sorting"]
        app.launch()
        XCTAssertTrue(app.staticTexts[ID.counter].waitForExistence(timeout: 5), "The sorting screen is up")
        // Let the launch settle: the photo's label names the file once its details are in.
        let named = NSPredicate(format: "label CONTAINS %@", ".HEIC")
        let settled = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: named, object: photo(in: app))], timeout: 5)
        XCTAssertEqual(settled, .completed, "The photo's details are in")
        Thread.sleep(forTimeInterval: 1.5)
        // The simulator connects its hardware keyboard on the first key event after launch and
        // swallows that event, so wake it with a key Piq ignores. Twice, a moment apart, in case
        // the first one came before the keyboard was listening.
        for _ in 0..<2 {
            app.typeKey(XCUIKeyboardKey.shift.rawValue, modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.5)
        }
        return app
    }

    /// ←, →, ← and ⌘Z.
    private func pressSortingKeys(_ app: XCUIApplication) {
        app.typeKey(.leftArrow, modifierFlags: [])
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey(.leftArrow, modifierFlags: [])
        app.typeKey("z", modifierFlags: .command)
    }

    private func photo(in app: XCUIApplication) -> XCUIElement {
        let photo = app.descendants(matching: .any)[ID.photo]
        XCTAssertTrue(photo.waitForExistence(timeout: 3), "The photo is on screen")
        return photo
    }

    /// Waits for the counter ("Photo 38 of 400") and the Review badge ("Review, 4 marked").
    private func expect(_ app: XCUIApplication, position: Int, marked: Int, file: StaticString = #filePath, line: UInt = #line) {
        let counter = app.staticTexts[ID.counter]
        let review = app.buttons[ID.review]
        let expectedCounter = "Photo \(position) of 400"
        let expectedReview = marked > 0 ? "Review, \(marked) marked" : "Review"
        let predicate = NSPredicate { _, _ in
            counter.label == expectedCounter && review.label == expectedReview
        }
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 4)
        XCTAssertEqual(result, .completed, "Expected “\(expectedCounter)” and “\(expectedReview)”, got “\(counter.label)” and “\(review.label)”", file: file, line: line)
    }
}
