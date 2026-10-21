import XCTest

/// Album picker states the screenshot tour doesn't reach (a tapped album, restricted access,
/// narrow windows, the header divider after scrolling), with checks on what VoiceOver and the UI
/// tests rely on: one button per album with its count, the selected trait, and the start button
/// with its Return shortcut.
@MainActor
final class AlbumPickerScreenshotExtras: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    func testSelectingAnAlbum() {
        let app = launch(scenario: "albums")
        let start = app.buttons["picker.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertTrue(app.scrollViews["picker.grid"].exists)
        XCTAssertTrue(app.staticTexts["Select an album"].exists)
        XCTAssertEqual(start.label, "Start sorting")
        XCTAssertFalse(start.isEnabled)

        let lisbon = app.buttons["picker.album.Weekend in Lisbon"]
        XCTAssertEqual(lisbon.label, "Weekend in Lisbon, 36 photos")
        XCTAssertFalse(lisbon.isSelected)
        lisbon.tap()
        XCTAssertTrue(lisbon.isSelected)
        XCTAssertTrue(app.staticTexts["Selected: Weekend in Lisbon"].exists)
        XCTAssertEqual(start.label, "Start sorting, 36 photos")
        XCTAssertTrue(start.isEnabled)
        attach("picker-selected")

        let drafts = app.buttons["picker.album.Drafts"]
        XCTAssertEqual(drafts.label, "Drafts, 0 photos")
        drafts.tap()
        XCTAssertTrue(drafts.isSelected)
        XCTAssertFalse(lisbon.isSelected)
        XCTAssertEqual(start.label, "Start sorting, 0 photos")
        XCTAssertFalse(start.isEnabled)
        attach("picker-empty-album")

        lisbon.tap()
        start.tap()
        XCTAssertTrue(app.scrollViews["picker.grid"].waitForNonExistence(timeout: 5), "Start sorting should leave the picker")
        app.terminate()
    }

    /// Return presses the start button (its `.defaultAction` shortcut), and does nothing while the
    /// button is disabled. XCUITest delivers Return only as "\n" typed into the window:
    /// `.return` and "\r" are dropped, and so are keys typed into the application element.
    func testReturnStartsSorting() {
        let app = launch(scenario: "albums")
        let grid = app.scrollViews["picker.grid"]
        XCTAssertTrue(app.buttons["picker.start"].waitForExistence(timeout: 5))
        let toast = app.descendants(matching: .any)["toast"]

        pressReturn(app)
        XCTAssertTrue(grid.exists, "Return shouldn't do anything with no album selected")
        XCTAssertFalse(toast.exists)

        app.buttons["picker.album.Drafts"].tap()
        pressReturn(app)
        XCTAssertTrue(grid.exists, "Return shouldn't open an album with no photos")
        XCTAssertFalse(toast.exists, "Return shouldn't try to open an album with no photos")

        app.buttons["picker.album.Weekend in Lisbon"].tap()
        pressReturn(app)
        XCTAssertTrue(grid.waitForNonExistence(timeout: 5), "Return should start sorting the selected album")
        app.terminate()
    }

    func testResumeFitsLandscape() {
        let app = launch(scenario: "resume")
        let start = app.buttons["picker.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertEqual(start.label, "Resume, 38 of 400")
        XCTAssertTrue(app.buttons["picker.album.Iceland 2026"].isSelected)
        XCTAssertTrue(app.staticTexts["Selected: Iceland 2026"].exists)

        // Two rows of albums fit a landscape window without scrolling.
        let title = app.staticTexts["Which album are we sorting?"]
        let titleFrame = title.frame
        app.scrollViews["picker.grid"].swipeUp()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(title.frame.minY, titleFrame.minY, accuracy: 0.5)
        attach("picker-resume")
        app.terminate()
    }

    func testRestrictedAndPortraitStates() {
        var app = launch(access: "restricted")
        XCTAssertTrue(app.buttons["picker.openSettings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.scrollViews["picker.grid"].exists)
        XCTAssertFalse(app.buttons["picker.start"].exists)
        XCTAssertTrue(app.staticTexts["Not connected"].exists)
        attach("picker-restricted")
        app.terminate()

        app = launch(access: "denied", orientation: .portrait)
        XCTAssertTrue(app.buttons["picker.openSettings"].waitForExistence(timeout: 5))
        attach("picker-denied")
        app.terminate()

        app = launch(access: "limited", orientation: .portrait)
        XCTAssertTrue(app.buttons["picker.changeSelection"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["picker.openPhotos"].label, "Connected to Photos, opens Photos")
        attach("picker-limited")
        app.terminate()
    }

    /// Shrinks the window with the iPadOS 26 resize grip in its bottom-right corner.
    func testNarrowWindows() {
        var app = launch(scenario: "resume")
        XCTAssertTrue(app.buttons["picker.start"].waitForExistence(timeout: 5))
        let fullWidth = app.windows.firstMatch.frame.width
        // iPadOS can remember a window's size across launches: give the full width back even if
        // this test fails, so later tests don't run in a narrow window.
        addTeardownBlock { @MainActor in
            let app = XCUIApplication()
            if app.state != .runningForeground {
                app.launchArguments = ["-PiqMockLibrary"]
                app.launch()
            }
            Self.resizeWindow(app, toWidth: fullWidth)
            app.terminate()
        }
        for width in [600.0, 500.0, 375.0] {
            Self.resizeWindow(app, toWidth: width)
            attach("picker-window-\(Int(width))")
        }
        app.scrollViews["picker.grid"].swipeUp()
        Thread.sleep(forTimeInterval: 1)
        attach("picker-window-375-scrolled")
        app.terminate()

        for access in ["limited", "restricted"] {
            app = launch(access: access)
            Self.resizeWindow(app, toWidth: 375)
            attach("picker-window-375-\(access)")
            app.terminate()
        }
    }

    // MARK: Helpers

    private func launch(scenario: String? = nil, access: String = "authorized", orientation: UIDeviceOrientation = .landscapeLeft) -> XCUIApplication {
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchArguments = ["-PiqMockLibrary", "-PiqMockAccess", access] + (scenario.map { ["-PiqMockScenario", $0] } ?? [])
        app.launch()
        XCUIDevice.shared.orientation = orientation
        Thread.sleep(forTimeInterval: 1.5)
        return app
    }

    private func pressReturn(_ app: XCUIApplication) {
        app.windows.firstMatch.typeKey("\n", modifierFlags: [])
        Thread.sleep(forTimeInterval: 1)
    }

    /// iPadOS resizes a centered window symmetrically, so the grip moves half the difference.
    private static func resizeWindow(_ app: XCUIApplication, toWidth width: CGFloat) {
        for _ in 0..<4 {
            let frame = app.windows.firstMatch.frame
            let excess = frame.width - width
            guard abs(excess) > 6 else { return }
            let grip = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.maxX - 4, dy: frame.maxY - 4))
            grip.press(forDuration: 0.6, thenDragTo: grip.withOffset(CGVector(dx: -excess / 2, dy: 0)))
            Thread.sleep(forTimeInterval: 1.2)
        }
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(name)-\(XCUIDevice.shared.orientation.isLandscape ? "landscape" : "portrait")"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
