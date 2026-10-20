import XCTest

/// Extra sorting screenshots that need input first: the screen right after a swipe to delete
/// (toast, badge and counter updated), in both orientations, the stack with photos of different
/// shapes, and a drag held past the threshold.
@MainActor
final class SortingScreenshotExtras: XCTestCase {
    /// A portrait photo behind a landscape one (42 of 400), then a landscape photo behind a
    /// portrait one (43 of 400), in both orientations: the card behind should only show as a
    /// sliver under the current photo.
    func testMixedShapesStack() {
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            let app = launch(orientation)
            let counter = app.staticTexts["sorting.counter"]
            for position in 39...43 {
                app.buttons["sorting.keep"].tap()
                let moved = NSPredicate(format: "label == %@", "Photo \(position) of 400")
                let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: moved, object: counter)], timeout: 3)
                XCTAssertEqual(result, .completed, "Keep moves on to photo \(position)")
                if position >= 42 {
                    Thread.sleep(forTimeInterval: 1)
                    attach("sorting-stack-\(position)", orientation)
                }
            }
            app.terminate()
        }
        XCUIDevice.shared.orientation = .portrait
    }

    func testAfterDelete() {
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            let app = launch(orientation)
            app.descendants(matching: .any)["sorting.photo"].swipeLeft()
            XCTAssertTrue(app.descendants(matching: .any)["toast"].waitForExistence(timeout: 2))
            attach("sorting-after-delete", orientation)
            app.terminate()
        }
        XCUIDevice.shared.orientation = .portrait
    }

    /// Holds the photo 180pt to the left, past the threshold, for a few seconds before letting
    /// go. A screenshot can't be taken from the test mid-gesture, so capture the held state from
    /// the host meanwhile (`xcrun simctl io <device> screenshot held.png`).
    func testHeldSwipe() {
        let app = launch(.landscapeLeft)
        let photo = app.descendants(matching: .any)["sorting.photo"]
        let start = photo.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.45))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: -180, dy: 14)), withVelocity: .slow, thenHoldForDuration: 4)
        let counter = app.staticTexts["sorting.counter"]
        let moved = NSPredicate(format: "label == %@", "Photo 39 of 400")
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: moved, object: counter)], timeout: 3)
        XCTAssertEqual(result, .completed, "Letting go past the threshold deletes the photo")
        attach("sorting-after-held-swipe", .landscapeLeft)
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch(_ orientation: UIDeviceOrientation) -> XCUIApplication {
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchArguments = ["-PiqMockLibrary", "-PiqMockAccess", "authorized", "-PiqMockScenario", "sorting"]
        app.launch()
        XCUIDevice.shared.orientation = orientation
        XCTAssertTrue(app.staticTexts["sorting.counter"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        return app
    }

    private func attach(_ name: String, _ orientation: UIDeviceOrientation) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(name)-\(orientation.isLandscape ? "landscape" : "portrait")"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
