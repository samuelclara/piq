import XCTest

/// The keyboard across the app: each screen's keys work on that screen and never on a screen
/// underneath it (the picker's Return under sorting, sorting's ← → ⌘Z under Review and the
/// preview, Review's ⌘A under the preview and the confirmation).
///
/// Keys go through the window and Escape is sent as ⌘. (see `ExperienceTestCase`).
final class ExperienceKeyboardTests: ExperienceTestCase {
    /// Return opens the selected album from the picker, and does nothing on the screens above it.
    func testReturnOnlyWorksOnThePicker() {
        let app = launch(scenario: "resume")
        XCTAssertTrue(app.buttons[ID.start].waitForExistence(timeout: 5))
        wakeKeyboard(app)
        pressReturn(app)
        expectSorting(app, position: 38, total: 400, marked: 4)

        pressReturn(app)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(app.scrollViews[ID.pickerGrid].exists, "Return on sorting doesn't go anywhere")
        expectSorting(app, position: 38, total: 400, marked: 4)

        app.buttons[ID.review].tap()
        XCTAssertTrue(element(ID.summary, in: app).waitForExistence(timeout: 4))
        pressReturn(app)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(element(ID.summary, in: app).exists, "Return on Review doesn't go anywhere")
        app.terminate()
    }

    /// With the preview open over Review (over sorting), no screen underneath takes a key: the
    /// photo stays where it was and nothing gets selected. ⌘. closes the preview only.
    func testNoKeyReachesTheScreensUnderThePreview() {
        let app = launch(scenario: "reviewPartial")
        XCTAssertTrue(element(ID.summary, in: app).waitForExistence(timeout: 5))
        wakeKeyboard(app)
        element(ID.tile("mock-asset-0011"), in: app).press(forDuration: 0.5)
        let close = app.buttons[ID.closePreview]
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 1)

        press(.leftArrow, in: app)
        press(.rightArrow, in: app)
        press("z", .command, in: app)
        press("a", .command, in: app)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(close.exists, "The keys left the preview open")

        XCTAssertTrue(dismissWithCancelShortcut(close, in: app), "⌘. closes the preview")
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(element(ID.summary, in: app).exists, "⌘. closed the preview only")
        XCTAssertFalse(app.buttons[ID.restore].isEnabled, "⌘A reached Review under the preview")
        XCTAssertEqual(app.buttons[ID.selectAll].label, "Select all")

        app.buttons[ID.reviewBack].tap()
        expectSorting(app, position: 121, total: 400, marked: 14)
        app.terminate()
    }

    /// ⌘A selects everything and deselects it again, but does nothing under the confirmation,
    /// which ⌘. closes with the trash untouched.
    func testReviewKeys() {
        let app = launch(scenario: "review")
        XCTAssertTrue(element(ID.summary, in: app).waitForExistence(timeout: 5))
        wakeKeyboard(app)
        let selectAll = app.buttons[ID.selectAll]

        press("a", .command, in: app)
        XCTAssertTrue(waitForLabel("Deselect all", of: selectAll))
        XCTAssertEqual(app.buttons[ID.restore].label, "Restore 50 photos")
        press("a", .command, in: app)
        XCTAssertTrue(waitForLabel("Select all", of: selectAll))

        app.buttons[ID.emptyTrash].tap()
        let confirm = app.buttons[ID.confirmDelete]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 0.5)
        press("a", .command, in: app)
        XCTAssertTrue(dismissWithCancelShortcut(confirm, in: app), "⌘. closes the confirmation")
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(selectAll.label, "Select all", "⌘A reached Review under the confirmation")
        XCTAssertTrue(labelled("50 to delete", in: app).exists)
        XCTAssertFalse(element(ID.toast, in: app).exists, "Nothing was deleted")
        app.terminate()
    }

    /// Sorting's keys still work after Review took the keyboard: ← and → decide, ⌘Z undoes,
    /// from the first press back on sorting.
    func testSortingKeysAfterReview() {
        let app = launch(scenario: "sorting")
        expectSorting(app, position: 38, total: 400, marked: 4)
        wakeKeyboard(app)
        press(.leftArrow, in: app)
        expectSorting(app, position: 39, total: 400, marked: 5)
        press(.rightArrow, in: app)
        expectSorting(app, position: 40, total: 400, marked: 5)

        app.buttons[ID.review].tap()
        XCTAssertTrue(element(ID.summary, in: app).waitForExistence(timeout: 4))
        press("a", .command, in: app)
        XCTAssertTrue(waitForLabel("Deselect all", of: app.buttons[ID.selectAll]))
        app.buttons[ID.reviewBack].tap()
        expectSorting(app, position: 40, total: 400, marked: 5)
        press("z", .command, in: app)
        expectSorting(app, position: 39, total: 400, marked: 5)
        press(.rightArrow, in: app)
        expectSorting(app, position: 40, total: 400, marked: 5)
        app.terminate()
    }

    /// Tab takes no screen's keys away: after a few presses of Tab, Return still opens the album
    /// from the picker, ← still decides on sorting and ⌘A still selects on Review.
    ///
    /// On iPadOS, Tab moves between buttons only with Full Keyboard Access, which follows the
    /// VoiceOver order; without it, Tab reaches text fields, and Piq has none. (XCUITest can't
    /// drive Full Keyboard Access: its synthesized keys never move the Full Keyboard Access focus.)
    func testTabTakesNoScreensKeys() {
        let app = launch(scenario: "resume")
        XCTAssertTrue(app.buttons[ID.start].waitForExistence(timeout: 5))
        wakeKeyboard(app)
        pressTab(3, in: app)
        pressReturn(app)
        expectSorting(app, position: 38, total: 400, marked: 4)

        pressTab(3, in: app)
        press(.leftArrow, in: app)
        expectSorting(app, position: 39, total: 400, marked: 5)

        app.buttons[ID.review].tap()
        XCTAssertTrue(element(ID.summary, in: app).waitForExistence(timeout: 4))
        pressTab(3, in: app)
        press("a", .command, in: app)
        XCTAssertTrue(waitForLabel("Deselect all", of: app.buttons[ID.selectAll]))
        app.terminate()
    }

    private func pressTab(_ count: Int, in app: XCUIApplication) {
        for _ in 0..<count {
            press(.tab, in: app)
            Thread.sleep(forTimeInterval: 0.3)
        }
    }
}
