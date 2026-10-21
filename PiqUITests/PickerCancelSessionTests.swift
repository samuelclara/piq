import XCTest

/// "Cancel session" in the picker's bottom bar, on the mock library: it asks first, "Keep Session"
/// leaves everything as it was, and "Cancel Session" forgets the session, so the album offers
/// "Start sorting" again and opens on its first photo. The "resume" scenario selects
/// "Iceland 2026" with a session at 38 of 400 and 4 photos marked.
@MainActor
final class PickerCancelSessionTests: ExperienceTestCase {
    private enum CancelID {
        static let cancelSession = "picker.cancelSession"
    }

    func testCancellingASessionAsksFirstThenStartsTheAlbumOver() {
        let app = launch(scenario: "resume")
        // The buttons' labels are spoken: "·" reads as a comma.
        let start = app.buttons[ID.start]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertEqual(start.label, "Resume, 38 of 400")
        let cancel = app.buttons[CancelID.cancelSession]
        XCTAssertTrue(cancel.exists, "an album with a session offers to cancel it")

        // Keep Session: nothing changes. On iPad the question is a popover, which a tap outside
        // also dismisses.
        cancel.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@", "Cancel Session")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        XCTAssertTrue(labelled("Cancel the session for Iceland 2026?", in: app).exists)
        shoot("picker-cancel-session-confirm", app)
        dismissPopover(app)
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 3))
        XCTAssertEqual(start.label, "Resume, 38 of 400")

        cancel.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()
        expectToast("Session cancelled", in: app)
        waitForLabel("Start sorting, 400 photos", of: start)
        XCTAssertFalse(cancel.exists, "nothing left to cancel")
        shoot("picker-cancel-session-done", app)

        start.tap()
        expectSorting(app, position: 1, total: 400, marked: 0)
    }

    func testAnAlbumWithoutASessionHasNothingToCancel() {
        let app = launch(scenario: "albums")
        let tile = element(ID.album("Weekend in Lisbon"), in: app)
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        tile.tap()
        waitForLabel("Start sorting, 36 photos", of: app.buttons[ID.start])
        XCTAssertFalse(app.buttons[CancelID.cancelSession].exists)
    }

    // MARK: Helpers

    /// Taps outside the popover, where iPadOS dismisses it.
    private func dismissPopover(_ app: XCUIApplication) {
        let outside = app.otherElements["PopoverDismissRegion"]
        XCTAssertTrue(outside.waitForExistence(timeout: 2))
        outside.tap()
    }
}
