import XCTest

/// Photos access and the library changing while a sorting or review screen is open, against the
/// mock library. The tests change the mock through `MockRemoteControl` (Darwin notifications).
/// Access changes take effect when Piq becomes active again, as after a trip to Settings, so
/// those tests go to the Home Screen and back. No simulator preparation is needed.
///
///     xcodebuild test -project Piq.xcodeproj -scheme Piq \
///       -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' \
///       -only-testing:PiqUITests/PersistenceLibraryChangeTests -resultBundlePath Changes.xcresult
@MainActor
final class PersistenceLibraryChangeTests: XCTestCase {
    private enum ID {
        static let start = "picker.start"
        static let openSettings = "picker.openSettings"
        static let changeSelection = "picker.changeSelection"
        static let counter = "sorting.counter"
        static let review = "sorting.review"
        static let photo = "sorting.photo"
        static let delete = "sorting.delete"
        static let summary = "review.summary"
        static let restore = "review.restore"
        static let closePreview = "review.closePreview"
        static let toast = "toast"
        static func album(_ title: String) -> String { "picker.album.\(title)" }
        static func tile(_ assetID: String) -> String { "review.tile.\(assetID)" }
    }

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: Photos access

    func testLosingAccessWhileSortingAndGettingItBack() {
        let app = launch(scenario: "sorting")
        expect(app, position: 38, total: 400, marked: 4)
        app.buttons[ID.delete].tap()
        expect(app, position: 39, total: 400, marked: 5)

        changeAccess(to: "denied", app)
        XCTAssertTrue(app.buttons[ID.openSettings].waitForExistence(timeout: 5), "the picker explains how to give access again")
        XCTAssertFalse(app.staticTexts[ID.counter].exists)
        attach("access-lost-while-sorting")

        changeAccess(to: "authorized", app)
        let start = app.buttons[ID.start]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        waitFor(start, label: "Resume · 39 of 400")
        XCTAssertTrue(app.buttons[ID.album("Iceland 2026")].isSelected)
        attach("access-back")
        start.tap()
        expect(app, position: 39, total: 400, marked: 5)
        app.terminate()
    }

    /// With the full-screen preview open on top of Review, too.
    func testLosingAccessWhileReviewing() {
        let app = launch(scenario: "review")
        XCTAssertTrue(element(ID.summary, in: app).waitForExistence(timeout: 10))
        element(ID.tile("mock-asset-0011"), in: app).press(forDuration: 0.5)
        XCTAssertTrue(app.buttons[ID.closePreview].waitForExistence(timeout: 3))

        changeAccess(to: "denied", app)
        XCTAssertTrue(app.buttons[ID.openSettings].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons[ID.closePreview].exists, "the preview went with the review screen")
        XCTAssertFalse(element(ID.summary, in: app).exists)
        attach("access-lost-while-reviewing")

        changeAccess(to: "authorized", app)
        let start = app.buttons[ID.start]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        waitFor(start, label: "Review · 50 photos marked")
        start.tap()
        XCTAssertTrue(element(ID.summary, in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(labelled("50 to delete", in: app).exists)
        app.terminate()
    }

    /// Limited access hides user albums: the one being sorted closes with a note, and resumes
    /// where it was once Piq has full access again.
    func testSwitchingToLimitedAccessWhileSortingAUserAlbum() {
        let app = launch(scenario: "sorting")
        expect(app, position: 38, total: 400, marked: 4)

        changeAccess(to: "limited", app)
        // The toast first: it is up for only 2.2 seconds.
        assertToast("Iceland 2026 needs full access to Photos", in: app)
        XCTAssertTrue(app.buttons[ID.changeSelection].waitForExistence(timeout: 5), "the limited-access picker")
        XCTAssertFalse(app.buttons[ID.album("Iceland 2026")].exists)
        attach("limited-while-sorting")

        changeAccess(to: "authorized", app)
        let start = app.buttons[ID.start]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        waitFor(start, label: "Resume · 38 of 400")
        start.tap()
        expect(app, position: 38, total: 400, marked: 4)
        app.terminate()
    }

    // MARK: Library changes

    func testThePhotoOnScreenDeletedElsewhere() {
        let app = launch(scenario: "sorting")
        expectPhoto(in: app, label: "Photo 38 of 400, IMG_4438.HEIC")

        post("photo.deleteCurrent")

        expect(app, position: 38, total: 399, marked: 4)
        expectPhoto(in: app, label: "Photo 38 of 399, IMG_4439.HEIC")
        attach("current-photo-deleted")
        app.terminate()
    }

    func testNewPhotosAddedWhileSortingAreQueued() {
        let app = launch(scenario: "sorting")
        expect(app, position: 38, total: 400, marked: 4)

        post("photos.add")

        expect(app, position: 38, total: 403, marked: 4)
        expectPhoto(in: app, label: "Photo 38 of 403, IMG_4438.HEIC")
        app.terminate()
    }

    func testTheAlbumDeletedWhileSorting() {
        let app = launch(scenario: "sorting")
        expect(app, position: 38, total: 400, marked: 4)

        post("album.delete")

        assertToast("Iceland 2026 is no longer in Photos", in: app)
        XCTAssertTrue(app.buttons[ID.start].waitForExistence(timeout: 5), "back on the albums")
        XCTAssertFalse(app.buttons[ID.album("Iceland 2026")].exists)
        XCTAssertFalse(app.staticTexts[ID.counter].exists)
        attach("album-deleted-while-sorting")
        app.terminate()
    }

    /// The grid, the counts and the selection stay in step when a photo in the trash is deleted
    /// in Photos while Review is open.
    func testAPhotoInTheTrashDeletedElsewhereWhileReviewing() {
        let app = launch(scenario: "review")
        XCTAssertTrue(element(ID.summary, in: app).waitForExistence(timeout: 10))
        // The first photo in the trash, and the next one.
        let deleted = element(ID.tile("mock-asset-0009"), in: app)
        let kept = element(ID.tile("mock-asset-0011"), in: app)
        deleted.tap()
        kept.tap()
        XCTAssertEqual(app.buttons[ID.restore].label, "Restore 2 photos")

        post("photo.deleteFirstMarked")

        XCTAssertTrue(deleted.waitForNonExistence(timeout: 5), "the deleted photo leaves the grid")
        XCTAssertTrue(labelled("49 to delete", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(labelled("399 sorted", in: app).exists)
        XCTAssertTrue(kept.isSelected)
        XCTAssertEqual(app.buttons[ID.restore].label, "Restore 1 photo")
        attach("trash-photo-deleted-while-reviewing")
        app.terminate()
    }

    // MARK: Helpers

    private func launch(scenario: String) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-PiqMockLibrary", "-PiqMockAccess", "authorized", "-PiqMockScenario", scenario]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 1)
        return app
    }

    /// Sends a `MockRemoteControl` command to the running app.
    private func post(_ command: String) {
        let name = CFNotificationName(("io.belleville.piq.mock." + command) as CFString)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), name, nil, nil, true)
    }

    /// Changes Photos access the way Settings would, then leaves Piq and comes back to it.
    private func changeAccess(to access: String, _ app: XCUIApplication) {
        post("access.\(access)")
        Thread.sleep(forTimeInterval: 0.5)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        app.activate()
    }

    /// Waits for the counter ("Photo 38 of 400") and the Review badge ("Review, 4 marked").
    private func expect(_ app: XCUIApplication, position: Int, total: Int, marked: Int, file: StaticString = #filePath, line: UInt = #line) {
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

    /// Waits for the photo's VoiceOver label to start with `label`.
    private func expectPhoto(in app: XCUIApplication, label: String, file: StaticString = #filePath, line: UInt = #line) {
        let photo = element(ID.photo, in: app)
        let named = NSPredicate { _, _ in photo.label.hasPrefix(label) }
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: named, object: nil)], timeout: 5)
        XCTAssertEqual(result, .completed, "Expected “\(label)…”, got “\(photo.label)”", file: file, line: line)
    }

    /// Waits for `element` to read `label` ("Resume · 7 of 400"). The "·" between the parts of a
    /// line may reach VoiceOver as a comma ("Resume, 7 of 400"), which counts as the same label.
    private func waitFor(_ element: XCUIElement, label: String, file: StaticString = #filePath, line: UInt = #line) {
        func spoken(_ text: String) -> String { text.replacingOccurrences(of: " · ", with: ", ") }
        let predicate = NSPredicate { _, _ in spoken(element.label) == spoken(label) }
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 5)
        XCTAssertEqual(result, .completed, "Expected “\(label)”, got “\(element.label)”", file: file, line: line)
    }

    private func assertToast(_ message: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let toast = element(ID.toast, in: app)
        XCTAssertTrue(toast.waitForExistence(timeout: 5), "no toast", file: file, line: line)
        XCTAssertTrue(toast.label.contains(message), "toast reads “\(toast.label)”", file: file, line: line)
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
