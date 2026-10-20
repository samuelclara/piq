import XCTest

/// Quitting Piq mid-session and launching it again, against the mock library with its on-disk
/// store (`-PiqMockPersistentStore`, apart from the real store; `-PiqMockResetStore` starts it
/// empty). "Iceland 2026" is the mock's first album, so its photo at position p is
/// `mock-asset-<p-1>`, named IMG_<4400+p>.HEIC. No simulator preparation is needed.
///
///     xcodebuild test -project Piq.xcodeproj -scheme Piq \
///       -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' \
///       -only-testing:PiqUITests/PersistenceRelaunchTests -resultBundlePath Relaunch.xcresult
@MainActor
final class PersistenceRelaunchTests: XCTestCase {
    private enum ID {
        static let start = "picker.start"
        static let back = "sorting.back"
        static let counter = "sorting.counter"
        static let undo = "sorting.undo"
        static let review = "sorting.review"
        static let photo = "sorting.photo"
        static let delete = "sorting.delete"
        static let keep = "sorting.keep"
        static let reviewBack = "review.back"
        static let summary = "review.summary"
        static let emptyTrash = "review.emptyTrash"
        static let confirmDelete = "review.confirmDelete"
        static func album(_ title: String) -> String { "picker.album.\(title)" }
        static func tile(_ assetID: String) -> String { "review.tile.\(assetID)" }
    }

    override func setUp() {
        continueAfterFailure = false
    }

    /// The everyday quit: Piq goes to the background (where it saves), then is quit from the app
    /// switcher. Everything comes back: the selection, the resume point, the photo on screen, the
    /// badge, the undo history and the trash.
    func testQuitFromTheBackgroundResumesExactly() {
        var app = launch(resettingStore: true)
        startSorting("Iceland 2026", in: app)
        // Photos 1 to 6: a mix of swipes and pills, the last one a delete.
        app.buttons[ID.delete].tap()
        expect(app, position: 2, marked: 1)
        app.buttons[ID.keep].tap()
        expect(app, position: 3, marked: 1)
        photo(in: app).swipeRight()
        expect(app, position: 4, marked: 1)
        photo(in: app).swipeLeft()
        expect(app, position: 5, marked: 2)
        app.buttons[ID.keep].tap()
        expect(app, position: 6, marked: 2)
        photo(in: app).swipeLeft()
        expect(app, position: 7, marked: 3)

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        app.terminate()
        app = launch(resettingStore: false)

        let start = app.buttons[ID.start]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        waitFor(start, label: "Resume · 7 of 400")
        XCTAssertTrue(app.buttons[ID.album("Iceland 2026")].isSelected, "the album being sorted is selected again")
        XCTAssertTrue(app.staticTexts["Selected: Iceland 2026"].exists)
        attach("relaunch-picker")

        start.tap()
        expect(app, position: 7, marked: 3)
        expectPhoto(in: app, position: 7)
        attach("relaunch-sorting")

        // The same trash: photos 1, 4 and 6.
        app.buttons[ID.review].tap()
        XCTAssertTrue(element(ID.summary, in: app).waitForExistence(timeout: 5))
        for assetID in ["mock-asset-0000", "mock-asset-0003", "mock-asset-0005"] {
            XCTAssertTrue(element(ID.tile(assetID), in: app).exists, "\(assetID) is still in the trash")
        }
        XCTAssertTrue(labelled("3 to delete", in: app).exists)
        XCTAssertTrue(labelled("3 kept", in: app).exists)
        attach("relaunch-review")
        app.buttons[ID.reviewBack].tap()
        XCTAssertTrue(element(ID.summary, in: app).waitForNonExistence(timeout: 5))

        // Undo reverses the last decision made before quitting: photo 6 comes back, unmarked.
        app.buttons[ID.undo].tap()
        expect(app, position: 6, marked: 2)
        expectPhoto(in: app, position: 6)
        app.terminate()
    }

    /// The harsh quit: Piq is killed the moment a swipe lands, without going to the background
    /// first (a crash, the system reclaiming memory), so nothing runs on the way out. Every
    /// decision that landed must still be there, that last one included.
    func testKilledAsASwipeLandsKeepsEveryDecision() {
        var app = launch(resettingStore: true)
        startSorting("Iceland 2026", in: app)
        app.buttons[ID.keep].tap()
        expect(app, position: 2, marked: 0)
        app.buttons[ID.delete].tap()
        expect(app, position: 3, marked: 1)
        app.buttons[ID.keep].tap()
        expect(app, position: 4, marked: 1)
        app.buttons[ID.keep].tap()
        expect(app, position: 5, marked: 1)
        post("app.killOnNextDecision")
        Thread.sleep(forTimeInterval: 0.3)
        photo(in: app).swipeLeft()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5), "Piq is killed as the swipe lands")

        app = launch(resettingStore: false)
        let start = app.buttons[ID.start]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        waitFor(start, label: "Resume · 6 of 400")
        start.tap()
        expect(app, position: 6, marked: 2)
        expectPhoto(in: app, position: 6)
        app.terminate()
    }

    /// Killed while the system's deletion prompt is up (the mock's stays up for 30 seconds):
    /// nothing was deleted, so the trash is exactly as it was.
    func testKilledWhileEmptyingTheTrashKeepsTheTrash() {
        var app = launch(resettingStore: true, extra: ["-PiqMockScenario", "review", "-PiqMockDeletionDelay", "30"])
        XCTAssertTrue(element(ID.summary, in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(labelled("50 to delete", in: app).exists)
        app.buttons[ID.emptyTrash].tap()
        let confirm = app.buttons[ID.confirmDelete]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 0.5)
        app.terminate()

        app = launch(resettingStore: false)
        let start = app.buttons[ID.start]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        waitFor(start, label: "Review · 50 photos marked")
        start.tap()
        XCTAssertTrue(element(ID.summary, in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(labelled("50 to delete", in: app).exists)
        XCTAssertTrue(labelled("400 sorted", in: app).exists)
        attach("relaunch-after-killed-emptying")
        app.terminate()
    }

    /// The picker selects the album the person sorted last, even when a change in Photos reached
    /// another session after it. Recents and Iceland 2026 start with the same photos, so deleting
    /// the one on screen in Photos is a change to both sessions, saved to both.
    func testTheAlbumSortedLastStaysSelectedAfterALibraryChange() {
        var app = launch(resettingStore: true)
        sortTwoPhotos(of: "Recents", total: 454, in: app)
        app.buttons[ID.back].tap()
        sortTwoPhotos(of: "Iceland 2026", total: 400, in: app)
        post("photo.deleteCurrent")
        expect(app, position: 3, total: 399, marked: 1)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        app.terminate()

        app = launch(resettingStore: false)
        let start = app.buttons[ID.start]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        waitFor(start, label: "Resume · 3 of 399")
        XCTAssertTrue(app.buttons[ID.album("Iceland 2026")].isSelected, "Iceland 2026 was sorted last")
        attach("relaunch-after-library-change")
        // Recents followed the change too.
        app.buttons[ID.album("Recents")].tap()
        waitFor(start, label: "Resume · 3 of 453")
        app.terminate()
    }

    // MARK: Helpers

    private func launch(resettingStore: Bool, extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-PiqMockLibrary", "-PiqMockAccess", "authorized", "-PiqMockPersistentStore"]
            + (resettingStore ? ["-PiqMockResetStore"] : []) + extra
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        return app
    }

    /// Sends a `MockRemoteControl` command to the running app.
    private func post(_ command: String) {
        let name = CFNotificationName(("io.belleville.piq.mock." + command) as CFString)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), name, nil, nil, true)
    }

    private func startSorting(_ album: String, in app: XCUIApplication) {
        let tile = app.buttons[ID.album(album)]
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        tile.tap()
        let start = app.buttons[ID.start]
        waitFor(start, label: "Start sorting · 400 photos")
        start.tap()
        expect(app, position: 1, marked: 0)
        expectPhoto(in: app, position: 1)
    }

    /// Starts sorting `album` (`total` photos), keeps its first photo and marks the second.
    private func sortTwoPhotos(of album: String, total: Int, in app: XCUIApplication) {
        let tile = app.buttons[ID.album(album)]
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        tile.tap()
        let start = app.buttons[ID.start]
        waitFor(start, label: "Start sorting · \(total) photos")
        start.tap()
        expect(app, position: 1, total: total, marked: 0)
        app.buttons[ID.keep].tap()
        expect(app, position: 2, total: total, marked: 0)
        app.buttons[ID.delete].tap()
        expect(app, position: 3, total: total, marked: 1)
    }

    private func photo(in app: XCUIApplication) -> XCUIElement {
        let photo = element(ID.photo, in: app)
        XCTAssertTrue(photo.waitForExistence(timeout: 5), "The photo is on screen")
        return photo
    }

    /// Waits for the photo at `position` of "Iceland 2026" to be on screen (its label names it).
    private func expectPhoto(in app: XCUIApplication, position: Int, file: StaticString = #filePath, line: UInt = #line) {
        let prefix = "Photo \(position) of 400, IMG_\(4400 + position).HEIC"
        let photo = photo(in: app)
        let named = NSPredicate { _, _ in photo.label.hasPrefix(prefix) }
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: named, object: nil)], timeout: 5)
        XCTAssertEqual(result, .completed, "Expected “\(prefix)…”, got “\(photo.label)”", file: file, line: line)
    }

    /// Waits for the counter ("Photo 7 of 400") and the Review badge ("Review, 3 marked").
    private func expect(_ app: XCUIApplication, position: Int, total: Int = 400, marked: Int, file: StaticString = #filePath, line: UInt = #line) {
        let counter = app.staticTexts[ID.counter]
        let review = app.buttons[ID.review]
        let expectedCounter = "Photo \(position) of \(total)"
        let expectedReview = marked > 0 ? "Review, \(marked) marked" : "Review"
        let predicate = NSPredicate { _, _ in
            counter.label == expectedCounter && review.label == expectedReview
        }
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 5)
        XCTAssertEqual(result, .completed, "Expected “\(expectedCounter)” and “\(expectedReview)”, got “\(counter.label)” and “\(review.label)”", file: file, line: line)
    }

    /// Waits for `element` to read `label` ("Resume · 7 of 400"). The "·" between the parts of a
    /// line may reach VoiceOver as a comma ("Resume, 7 of 400"), which counts as the same label.
    private func waitFor(_ element: XCUIElement, label: String, file: StaticString = #filePath, line: UInt = #line) {
        func spoken(_ text: String) -> String { text.replacingOccurrences(of: " · ", with: ", ") }
        let predicate = NSPredicate { _, _ in spoken(element.label) == spoken(label) }
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 5)
        XCTAssertEqual(result, .completed, "Expected “\(label)”, got “\(element.label)”", file: file, line: line)
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func labelled(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
