import XCTest

/// "Connected to Photos" opens the Photos app; without access the header keeps saying "Not
/// connected", with nothing to tap.
@MainActor
final class PickerPhotosLinkTests: ExperienceTestCase {
    func testConnectedToPhotosOpensPhotos() {
        let app = launch(scenario: "albums")
        let link = app.buttons["picker.openPhotos"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        XCTAssertEqual(link.label, "Connected to Photos, opens Photos")
        XCTAssertTrue(app.staticTexts["Connected to Photos"].exists, "the words on screen are still there as text")
        XCTAssertGreaterThanOrEqual(link.frame.height, 44)
        XCTAssertGreaterThanOrEqual(link.frame.width, 44)
        XCTAssertLessThan(link.frame.minY, labelled("Which album are we sorting?", in: app).frame.minY, "in the header, above the title")
        shoot("picker-photos-link", app)

        link.tap()
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        XCTAssertTrue(photos.wait(for: .runningForeground, timeout: 15), "Tapping it opens Photos")
        photos.terminate()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(link.waitForExistence(timeout: 5), "Back in Piq, on the picker")
        app.terminate()
    }

    func testNotConnectedIsPlainText() {
        for access in ["denied", "restricted"] {
            let app = launch(access: access)
            XCTAssertTrue(app.buttons[ID.openSettings].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Not connected"].exists)
            XCTAssertFalse(app.buttons["picker.openPhotos"].exists)
            app.terminate()
        }
    }
}
