import XCTest

/// Previous and Next on the sorting screen with real input, on the mock library: the chevron
/// buttons, ⌘[ and ⌘], a revisited photo and its decision (read in the photo's VoiceOver label),
/// changing a decision there, skipping to the end and on to Review, resuming at the first
/// unsorted photo, and a relaunch with the on-disk mock store. The "Iceland 2026" scenario opens
/// at 38 of 400, photos 10, 12, 26 and 28 marked, the others kept.
@MainActor
final class NavigationFlowTests: ExperienceTestCase {
    private enum NavID {
        static let previous = "sorting.previous"
        static let next = "sorting.next"
    }

    func testTheButtonsMoveWithoutDeciding() {
        let app = launch(scenario: "sorting")
        expectSorting(app, position: 38, total: 400, marked: 4)
        let previous = app.buttons[NavID.previous]
        let next = app.buttons[NavID.next]
        XCTAssertEqual(previous.label, "Previous photo")
        XCTAssertEqual(next.label, "Next photo")
        XCTAssertTrue(previous.isEnabled)

        next.tap()
        expectSorting(app, position: 39, total: 400, marked: 4)
        expectPhoto(app, "Photo 39 of 400, IMG_4439.HEIC", decision: nil)
        previous.tap()
        previous.tap()
        expectSorting(app, position: 37, total: 400, marked: 4)
        expectPhoto(app, "Photo 37 of 400, IMG_4437.HEIC", decision: "kept")
        for _ in 0..<9 {
            previous.tap()
        }
        expectPhoto(app, "Photo 28 of 400, IMG_4428.HEIC", decision: "marked for deletion")

        // Undo is unchanged: it takes back the last decision (photo 37's keep) and shows it.
        app.buttons[ID.undo].tap()
        expectSorting(app, position: 37, total: 400, marked: 4)
        expectPhoto(app, "Photo 37 of 400, IMG_4437.HEIC", decision: nil)
    }

    /// ⌘] and ⌘[ move; ← and → on a revisited photo replace its decision (with the toast for a
    /// delete) and move on; ⌘Z puts the earlier decision back.
    func testKeysAndChangingADecision() {
        let app = launch(scenario: "sorting")
        expectSorting(app, position: 38, total: 400, marked: 4)
        wakeKeyboard(app)

        press("]", .command, in: app)
        expectSorting(app, position: 39, total: 400, marked: 4)
        press("[", .command, in: app)
        press("[", .command, in: app)
        expectSorting(app, position: 37, total: 400, marked: 4)
        expectPhoto(app, "Photo 37 of 400", decision: "kept")

        press(.leftArrow, in: app)
        expectToast("Marked for deletion", in: app)
        expectSorting(app, position: 38, total: 400, marked: 5)
        press("[", .command, in: app)
        expectPhoto(app, "Photo 37 of 400", decision: "marked for deletion")
        shoot("nav-changed-to-delete", app)

        press(.rightArrow, in: app)
        expectSorting(app, position: 38, total: 400, marked: 4)

        press("z", .command, in: app)
        expectSorting(app, position: 37, total: 400, marked: 5)
        expectPhoto(app, "Photo 37 of 400", decision: "marked for deletion")
        press("z", .command, in: app)
        expectSorting(app, position: 37, total: 400, marked: 4)
        expectPhoto(app, "Photo 37 of 400", decision: "kept")
    }

    func testPreviousIsDimmedOnTheFirstPhoto() {
        let app = launch(scenario: "sortingStart")
        expectSorting(app, position: 1, total: 400, marked: 0)
        XCTAssertFalse(app.buttons[NavID.previous].isEnabled, "nothing before the first photo")
        XCTAssertTrue(app.buttons[NavID.next].isEnabled)
        wakeKeyboard(app)
        press("[", .command, in: app)
        app.buttons[NavID.previous].tap()
        expectSorting(app, position: 1, total: 400, marked: 0)
        press("]", .command, in: app)
        expectSorting(app, position: 2, total: 400, marked: 0)
        XCTAssertTrue(app.buttons[NavID.previous].isEnabled)
    }

    /// Skipping to the end of Family goes on to Review, which says how many are sorted and offers
    /// to continue; "Continue sorting" and the picker's Resume both go to the first unsorted photo.
    func testSkippingToTheEndOpensReviewAndResumingGoesToTheFirstUnsortedPhoto() {
        let app = launch()
        let tile = app.buttons[ID.album("Family")]
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        tile.tap()
        let start = app.buttons[ID.start]
        start.tap()
        expectSorting(app, position: 1, total: 18, marked: 0)
        app.buttons[ID.keep].tap()
        expectSorting(app, position: 2, total: 18, marked: 0)
        app.buttons[NavID.next].tap()
        expectSorting(app, position: 3, total: 18, marked: 0)
        app.buttons[ID.delete].tap()
        for position in 4...18 {
            expectSorting(app, position: position, total: 18, marked: 1)
            app.buttons[NavID.next].tap()
        }

        let summary = element(ID.summary, in: app)
        XCTAssertTrue(summary.waitForExistence(timeout: 5), "Review opens past the last photo")
        waitForLabel("2 of 18 sorted so far. Nothing is deleted until you empty the trash.", of: summary)
        let back = app.buttons[ID.reviewBack]
        XCTAssertEqual(back.label, "Continue sorting")
        back.tap()
        expectSorting(app, position: 2, total: 18, marked: 1)
        expectPhoto(app, "Photo 2 of 18", decision: nil)

        app.buttons[ID.sortingBack].tap()
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        waitForLabel("Resume, 2 of 18", of: start)
        start.tap()
        expectSorting(app, position: 2, total: 18, marked: 1)
    }

    /// Review is pushed on top of sorting, which stays alive underneath: ⌘[ and ⌘] must not move
    /// it from there.
    func testMoveKeysDoNothingUnderReview() {
        let app = launch(scenario: "sorting")
        expectSorting(app, position: 38, total: 400, marked: 4)
        wakeKeyboard(app)
        app.buttons[ID.review].tap()
        let back = app.buttons[ID.reviewBack]
        XCTAssertTrue(back.waitForExistence(timeout: 3))
        press("[", .command, in: app)
        press("]", .command, in: app)
        press("]", .command, in: app)
        back.tap()
        XCTAssertTrue(back.waitForNonExistence(timeout: 3))
        expectSorting(app, position: 38, total: 400, marked: 4)
        press("]", .command, in: app)
        expectSorting(app, position: 39, total: 400, marked: 4)
    }

    /// In a narrow window Previous and Next have a row of their own under the photo, over Delete
    /// and Keep and clear of the toasts under the top bar, and work the same.
    func testANarrowWindowHasPreviousAndNextUnderThePhoto() {
        let app = launch(scenario: "sorting")
        expectSorting(app, position: 38, total: 400, marked: 4)
        resizeWindow(app, toWidth: 400)
        let previous = app.buttons[NavID.previous]
        XCTAssertTrue(previous.waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(previous.frame.minY, element(ID.photo, in: app).frame.maxY, "under the photo")
        XCTAssertLessThanOrEqual(previous.frame.maxY, app.buttons[ID.delete].frame.minY, "over Delete")
        XCTAssertGreaterThanOrEqual(previous.frame.height, 44)
        app.buttons[NavID.next].tap()
        expectSorting(app, position: 39, total: 400, marked: 4)
        previous.tap()
        previous.tap()
        expectPhoto(app, "Photo 37 of 400", decision: "kept")
        shoot("nav-narrow-revisit", app)
        // The toast a deletion shows leaves the row in sight.
        app.buttons[ID.delete].tap()
        let toast = element(ID.toast, in: app)
        XCTAssertTrue(toast.waitForExistence(timeout: 3))
        XCTAssertLessThan(toast.frame.maxY, previous.frame.minY, "the toast is above the row")
        shoot("nav-narrow-toast", app)
    }

    // MARK: Helpers

    /// Waits for the photo's VoiceOver label to start with `prefix` and end with its decision
    /// (", kept", ", marked for deletion"), or with no decision for an unsorted photo.
    private func expectPhoto(_ app: XCUIApplication, _ prefix: String, decision: String?, file: StaticString = #filePath, line: UInt = #line) {
        let photo = element(ID.photo, in: app)
        let decisions = [", kept", ", marked for deletion"]
        let predicate = NSPredicate { _, _ in
            guard photo.exists else { return false }
            let label = photo.label
            guard label.hasPrefix(prefix) else { return false }
            if let decision {
                return label.hasSuffix(", \(decision)")
            }
            return !decisions.contains { label.hasSuffix($0) }
        }
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 5)
        XCTAssertEqual(result, .completed, "Expected “\(prefix)…\(decision.map { ", \($0)" } ?? "")”, got “\(photo.exists ? photo.label : "-")”", file: file, line: line)
    }
}
