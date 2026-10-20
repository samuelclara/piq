import XCTest

/// Review-screen states the tour can't reach by launching alone (a selection, the confirm card,
/// the full-screen preview) and the restore and empty-the-trash flows, against the mock library.
/// The "review" scenario has 400 photos sorted and 50 in the trash.
///
///     xcodebuild test -project Piq.xcodeproj -scheme Piq \
///       -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' \
///       -only-testing:PiqUITests/ReviewScreenshotExtras -resultBundlePath Review.xcresult
@MainActor
final class ReviewScreenshotExtras: XCTestCase {
    private enum ID {
        static let summary = "review.summary"
        static let selectAll = "review.selectAll"
        static let restore = "review.restore"
        static let emptyTrash = "review.emptyTrash"
        static let confirmDelete = "review.confirmDelete"
        static let cancelDelete = "review.cancelDelete"
        static let emptyState = "review.emptyState"
        static let emptyStateButton = "review.emptyStateButton"
        static let closePreview = "review.closePreview"
        static let toast = "toast"
        static func tile(_ assetID: String) -> String { "review.tile.\(assetID)" }
    }

    /// The first photos in the trash, all on the first rows in both orientations.
    private let firstMarked = ["mock-asset-0011", "mock-asset-0025", "mock-asset-0043"]
    /// The last photo in the trash.
    private let lastMarked = "mock-asset-0395"
    /// An ordinary long press: a little over the tiles' 0.4s threshold.
    private static let longPress: TimeInterval = 0.5

    func testALongPressPreviewsAndATapSelects() {
        continueAfterFailure = false
        let app = launch(scenario: "review")
        let tile = element(ID.tile(firstMarked[0]), in: app)
        let close = app.buttons[ID.closePreview]
        let frame = tile.frame

        tile.press(forDuration: Self.longPress)
        XCTAssertTrue(close.waitForExistence(timeout: 3), "a half-second press opens the preview")
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertFalse(tile.isSelected, "the long press didn't select")
        XCTAssertEqual(tile.frame, frame, "the tile is back to full size")

        tile.tap()
        XCTAssertTrue(tile.isSelected, "a tap selects")
        XCTAssertFalse(close.exists, "a tap doesn't preview")
        finish(app)
    }

    func testSelectionConfirmAndPreview() {
        continueAfterFailure = false
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            let app = launch(scenario: "review", orientation: orientation)

            for assetID in firstMarked {
                element(ID.tile(assetID), in: app).tap()
            }
            XCTAssertTrue(element(ID.tile(firstMarked[0]), in: app).isSelected)
            XCTAssertEqual(app.buttons[ID.restore].label, "Restore 3 photos")
            capture("review-selection", orientation)

            app.buttons[ID.selectAll].tap()
            XCTAssertEqual(app.buttons[ID.selectAll].label, "Deselect all")
            capture("review-all-selected", orientation)
            app.buttons[ID.selectAll].tap()
            XCTAssertEqual(app.buttons[ID.selectAll].label, "Select all")
            XCTAssertFalse(app.buttons[ID.restore].isEnabled)

            app.buttons[ID.emptyTrash].tap()
            let confirm = app.buttons[ID.confirmDelete]
            XCTAssertTrue(confirm.waitForExistence(timeout: 3))
            XCTAssertEqual(confirm.label, "Delete 50 photos")
            XCTAssertTrue(labelled("Delete 50 photos?", in: app).exists)
            Thread.sleep(forTimeInterval: 0.6)
            capture("review-confirm", orientation)
            app.buttons[ID.cancelDelete].tap()
            XCTAssertTrue(confirm.waitForNonExistence(timeout: 3))

            element(ID.tile(firstMarked[1]), in: app).press(forDuration: Self.longPress)
            let close = app.buttons[ID.closePreview]
            XCTAssertTrue(close.waitForExistence(timeout: 3))
            Thread.sleep(forTimeInterval: 1.2)
            capture("review-preview", orientation)
            close.tap()
            XCTAssertTrue(close.waitForNonExistence(timeout: 3))
            XCTAssertFalse(element(ID.tile(firstMarked[1]), in: app).isSelected, "a long press previews without selecting")

            finish(app)
        }
    }

    func testPreviewShowsTheQuickImageWhileTheSharpOneLoads() {
        continueAfterFailure = false
        let app = launch(scenario: "review", extra: ["-PiqMockLatency", "30"])
        element(ID.tile(firstMarked[0]), in: app).press(forDuration: Self.longPress)
        XCTAssertTrue(app.buttons[ID.closePreview].waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 1)
        capture("review-preview-loading", .landscapeLeft)
        finish(app)
    }

    func testPreviewClosesWithTheCancelShortcutAndASwipeDown() {
        continueAfterFailure = false
        let app = launch(scenario: "review")
        let tile = element(ID.tile(firstMarked[0]), in: app)
        let close = app.buttons[ID.closePreview]

        tile.press(forDuration: Self.longPress)
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(dismissWithCancelShortcut(close, in: app), "the cancel shortcut closes the preview")

        tile.press(forDuration: Self.longPress)
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 1)
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(close.waitForNonExistence(timeout: 3), "a swipe down closes the preview")
        XCTAssertFalse(tile.isSelected)
        finish(app)
    }

    func testCancelShortcutDismissesTheConfirmation() {
        continueAfterFailure = false
        let app = launch(scenario: "review")
        app.buttons[ID.emptyTrash].tap()
        let confirm = app.buttons[ID.confirmDelete]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(dismissWithCancelShortcut(confirm, in: app), "the cancel shortcut closes the card")
        XCTAssertTrue(labelled("50 to delete", in: app).exists)
        finish(app)
    }

    func testGridScrollsToTheLastPhoto() {
        continueAfterFailure = false
        let app = launch(scenario: "review")
        let last = element(ID.tile(lastMarked), in: app)
        for _ in 0..<8 where !(last.exists && last.isHittable) {
            app.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(last.isHittable, "the grid scrolls through the whole trash")
        XCTAssertFalse(app.buttons[ID.restore].isEnabled, "scrolling from a tile selects nothing")
        Thread.sleep(forTimeInterval: 0.5)
        capture("review-scrolled", .landscapeLeft)
        finish(app)
    }

    func testRestoringTakesPhotosOffTheList() {
        continueAfterFailure = false
        let app = launch(scenario: "review")
        element(ID.tile(firstMarked[0]), in: app).tap()
        element(ID.tile(firstMarked[1]), in: app).tap()
        app.buttons[ID.restore].tap()

        assertToast("2 photos restored", in: app)
        XCTAssertFalse(element(ID.tile(firstMarked[0]), in: app).exists)
        XCTAssertTrue(labelled("48 to delete", in: app).exists)
        XCTAssertTrue(labelled("352 kept", in: app).exists)
        XCTAssertFalse(app.buttons[ID.restore].isEnabled)
        capture("review-restored", .landscapeLeft)
        finish(app)
    }

    func testEmptyingTheTrashMovesEverythingToRecentlyDeleted() {
        continueAfterFailure = false
        let app = launch(scenario: "review")
        app.buttons[ID.emptyTrash].tap()
        let confirm = app.buttons[ID.confirmDelete]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()

        assertToast("50 photos moved to Recently Deleted", in: app)
        XCTAssertTrue(element(ID.emptyState, in: app).waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons[ID.emptyStateButton].label, "Back to albums")
        XCTAssertTrue(labelled("0 to delete", in: app).exists)
        capture("review-trash-emptied", .landscapeLeft)
        finish(app)
    }

    func testDecliningTheSystemPromptKeepsTheTrash() {
        continueAfterFailure = false
        let app = launch(scenario: "review", extra: ["-PiqMockDeletion", "cancel"])
        element(ID.tile(firstMarked[0]), in: app).tap()
        app.buttons[ID.emptyTrash].tap()
        let confirm = app.buttons[ID.confirmDelete]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()

        // The mock answers the "system prompt" after 350ms; give it time to settle.
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertFalse(element(ID.toast, in: app).exists, "declining says nothing")
        XCTAssertFalse(element(ID.emptyState, in: app).exists)
        XCTAssertTrue(labelled("50 to delete", in: app).exists)
        XCTAssertTrue(element(ID.tile(firstMarked[0]), in: app).isSelected, "the selection survives")
        XCTAssertTrue(app.buttons[ID.emptyTrash].isHittable)
        capture("review-delete-declined", .landscapeLeft)
        finish(app)
    }

    /// A second tap on "Delete 50 photos" while the card closes must not start a second request
    /// (which used to clear the selection the person then kept by declining).
    func testTappingDeleteTwiceAsksOnce() {
        continueAfterFailure = false
        let app = launch(scenario: "review", extra: ["-PiqMockDeletion", "cancel"])
        let tile = element(ID.tile(firstMarked[0]), in: app)
        tile.tap()
        app.buttons[ID.emptyTrash].tap()
        let confirm = app.buttons[ID.confirmDelete]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.doubleTap()

        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertFalse(element(ID.toast, in: app).exists, "declining says nothing")
        XCTAssertTrue(labelled("50 to delete", in: app).exists)
        XCTAssertTrue(tile.isSelected, "the selection survives")
        XCTAssertEqual(app.buttons[ID.restore].label, "Restore 1 photo")
        finish(app)
    }

    func testFailedDeletionSaysSo() {
        continueAfterFailure = false
        let app = launch(scenario: "review", extra: ["-PiqMockDeletion", "fail"])
        app.buttons[ID.emptyTrash].tap()
        app.buttons[ID.confirmDelete].tap()
        assertToast("Couldn't delete the photos", in: app)
        XCTAssertTrue(labelled("50 to delete", in: app).exists)
        finish(app)
    }

    func testEmptyTrashGoesBackToSorting() {
        continueAfterFailure = false
        let app = launch(scenario: "emptyTrash")
        XCTAssertTrue(element(ID.emptyState, in: app).exists)
        let button = app.buttons[ID.emptyStateButton]
        XCTAssertEqual(button.label, "Continue sorting")
        // Once in a full run, a tap right after an accessibility hiccup (kAXErrorServerNotFound)
        // never arrived: wait until the button can be hit, and tap once more if Review stays.
        XCTAssertTrue(waitUntilHittable(button))
        button.tap()
        let summary = element(ID.summary, in: app)
        if !summary.waitForNonExistence(timeout: 3), button.exists, button.isHittable {
            button.tap()
        }
        XCTAssertTrue(summary.waitForNonExistence(timeout: 3))
        finish(app)
    }

    // MARK: Helpers

    private func launch(scenario: String, orientation: UIDeviceOrientation = .landscapeLeft, extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchArguments = ["-PiqMockLibrary", "-PiqMockAccess", "authorized", "-PiqMockScenario", scenario] + extra
        app.launch()
        XCUIDevice.shared.orientation = orientation
        XCTAssertTrue(element(ID.summary, in: app).waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        return app
    }

    private func finish(_ app: XCUIApplication) {
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Triggers `.keyboardShortcut(.cancelAction)` (Escape or ⌘.) and waits for `element` to go
    /// away. XCUITest's synthesized Escape doesn't reach apps on the iPadOS 26 simulator, so this
    /// sends ⌘., the same shortcut. The simulator also drops synthesized keys now and then (often
    /// the first after a launch), so it tries up to three times; an unwired shortcut fails all three.
    private func dismissWithCancelShortcut(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<3 {
            app.typeKey(".", modifierFlags: .command)
            if element.waitForNonExistence(timeout: 1.5) { return true }
        }
        return false
    }

    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "isHittable == true")
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    private func labelled(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func assertToast(_ message: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let toast = element(ID.toast, in: app)
        XCTAssertTrue(toast.waitForExistence(timeout: 5), "no toast", file: file, line: line)
        XCTAssertTrue(toast.label.contains(message), "toast reads \"\(toast.label)\"", file: file, line: line)
    }

    private func capture(_ name: String, _ orientation: UIDeviceOrientation) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(name)-\(orientation.isLandscape ? "landscape" : "portrait")"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
