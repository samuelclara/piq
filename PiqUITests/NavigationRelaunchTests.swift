import XCTest

/// Quitting Piq after moving through the photos and changing a decision, then launching it again,
/// against the mock library with its on-disk store (`-PiqMockPersistentStore`; `-PiqMockResetStore`
/// starts it empty). A scenario launch over a store that already has its session opens that
/// session as it was saved, cursor included, so the relaunch shows where the cursor was; the
/// picker's Resume then goes to the first unsorted photo. No simulator preparation is needed.
@MainActor
final class NavigationRelaunchTests: ExperienceTestCase {
    private enum NavID {
        static let previous = "sorting.previous"
        static let next = "sorting.next"
    }

    func testARelaunchKeepsTheCursorAndTheDecisions() {
        var app = launch(scenario: "sorting", extra: ["-PiqMockPersistentStore", "-PiqMockResetStore"])
        expectSorting(app, position: 38, total: 400, marked: 4)
        // Back to photo 35 (kept), mark it for deletion instead, and move on to 37.
        for _ in 0..<3 {
            app.buttons[NavID.previous].tap()
        }
        expectSorting(app, position: 35, total: 400, marked: 4)
        app.buttons[ID.delete].tap()
        expectSorting(app, position: 36, total: 400, marked: 5)
        app.buttons[NavID.next].tap()
        expectSorting(app, position: 37, total: 400, marked: 5)

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        app.terminate()
        app = launch(scenario: "sorting", extra: ["-PiqMockPersistentStore"])

        expectSorting(app, position: 37, total: 400, marked: 5)
        shoot("nav-relaunch", app)
        app.buttons[NavID.previous].tap()
        app.buttons[NavID.previous].tap()
        expectSorting(app, position: 35, total: 400, marked: 5)
        let photo = element(ID.photo, in: app)
        XCTAssertTrue(photo.label.hasPrefix("Photo 35 of 400, IMG_4435.HEIC"), photo.label)
        XCTAssertTrue(photo.label.hasSuffix(", marked for deletion"), photo.label)

        // The picker resumes at the first unsorted photo, 38.
        app.buttons[ID.sortingBack].tap()
        let start = app.buttons[ID.start]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        waitForLabel("Resume, 38 of 400", of: start)
        start.tap()
        expectSorting(app, position: 38, total: 400, marked: 5)
        app.buttons[ID.undo].tap()
        expectSorting(app, position: 35, total: 400, marked: 4)
    }
}
