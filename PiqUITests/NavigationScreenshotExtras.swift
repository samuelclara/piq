import XCTest

/// Screenshots of Previous and Next on the sorting screen, on the mock library: the chevrons by
/// the counter in landscape, portrait and narrow windows, a revisited photo with its decision tag,
/// the first photo (Previous dimmed) and the end of the album with photos skipped. They attach
/// to the result bundle; look at them with `xcrun xcresulttool export attachments`.
@MainActor
final class NavigationScreenshotExtras: ExperienceTestCase {
    private enum NavID {
        static let previous = "sorting.previous"
        static let next = "sorting.next"
    }

    func testRevisitedPhotosInLandscapeAndPortrait() {
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            let app = launch(scenario: "sorting", orientation: orientation)
            expectSorting(app, position: 38, total: 400, marked: 4)
            shoot("nav-sorting", app)
            // Photo 28 is marked for deletion, 37 kept.
            app.buttons[NavID.previous].tap()
            expectSorting(app, position: 37, total: 400, marked: 4)
            Thread.sleep(forTimeInterval: 0.8)
            shoot("nav-revisit-kept", app)
            for _ in 0..<9 {
                app.buttons[NavID.previous].tap()
            }
            expectSorting(app, position: 28, total: 400, marked: 4)
            Thread.sleep(forTimeInterval: 0.8)
            shoot("nav-revisit-marked", app)
            app.terminate()
        }
    }

    func testTheFirstPhotoAndNarrowWindows() {
        let app = launch(scenario: "sortingStart")
        expectSorting(app, position: 1, total: 400, marked: 0)
        Thread.sleep(forTimeInterval: 0.6)
        shoot("nav-first-photo", app)
        for width in [700.0, 500, 380] {
            resizeWindow(app, toWidth: width)
            Thread.sleep(forTimeInterval: 0.6)
            shoot("nav-first-photo", app)
        }
        app.buttons[NavID.next].tap()
        expectSorting(app, position: 2, total: 400, marked: 0)
        app.buttons[NavID.previous].tap()
        app.buttons["sorting.delete"].tap()
        app.buttons[NavID.previous].tap()
        expectSorting(app, position: 1, total: 400, marked: 1)
        Thread.sleep(forTimeInterval: 0.8)
        shoot("nav-revisit-marked", app)
    }

    /// Past the last photo of Family with photos skipped: Review comes up and says what's left.
    func testTheEndOfTheAlbumWithPhotosSkipped() {
        let app = launch()
        let tile = app.buttons[ID.album("Family")]
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        tile.tap()
        app.buttons[ID.start].tap()
        expectSorting(app, position: 1, total: 18, marked: 0)
        app.buttons[ID.delete].tap()
        for position in 2...18 {
            expectSorting(app, position: position, total: 18, marked: 1)
            app.buttons[NavID.next].tap()
        }
        XCTAssertTrue(element(ID.summary, in: app).waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.6)
        shoot("nav-review-after-skipping", app)
    }
}
