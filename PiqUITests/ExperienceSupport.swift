import XCTest

/// Shared ground for the Experience UI tests: launching the mock library in an orientation,
/// resizing the window, typing keys the way the simulator accepts them, waiting on labels, and
/// attaching screenshots and accessibility snapshots.
///
/// Recipes (iPadOS 26.5 simulator):
/// - Keys go through the window (`app.windows.firstMatch.typeKey`); the simulator drops the
///   first synthesized key after a launch, so `wakeKeyboard()` sends a harmless Shift first.
/// - Return is typed as "\n". Escape never reaches the app; ⌘. triggers the same
///   `.cancelAction` shortcut.
/// - Rotation only works from a UI test (`XCUIDevice.shared.orientation`), set again after launch.
/// - Windows are resized with the grip in their bottom-right corner. iPadOS remembers a window's
///   size across launches, so every test that resizes gives the full width back when it ends.
@MainActor
class ExperienceTestCase: XCTestCase {
    enum ID {
        static let pickerGrid = "picker.grid"
        static let start = "picker.start"
        static let openSettings = "picker.openSettings"
        static let changeSelection = "picker.changeSelection"
        static func album(_ title: String) -> String { "picker.album.\(title)" }

        static let sortingBack = "sorting.back"
        static let counter = "sorting.counter"
        static let undo = "sorting.undo"
        static let review = "sorting.review"
        static let photo = "sorting.photo"
        static let delete = "sorting.delete"
        static let keep = "sorting.keep"

        static let reviewBack = "review.back"
        static let summary = "review.summary"
        static let selectAll = "review.selectAll"
        static let restore = "review.restore"
        static let emptyTrash = "review.emptyTrash"
        static let confirmDelete = "review.confirmDelete"
        static let cancelDelete = "review.cancelDelete"
        static let emptyState = "review.emptyState"
        static let emptyStateButton = "review.emptyStateButton"
        static let closePreview = "review.closePreview"
        static func tile(_ assetID: String) -> String { "review.tile.\(assetID)" }

        static let toast = "toast"
    }

    /// The full-screen width, recorded before a test resizes the window.
    private var fullWidth: CGFloat?

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
    }

    // MARK: Launching

    /// Launches Piq on the mock library and settles it in `orientation`.
    @discardableResult
    func launch(
        scenario: String? = nil,
        access: String = "authorized",
        orientation: UIDeviceOrientation = .landscapeLeft,
        extra: [String] = [],
        settle: TimeInterval = 1.5
    ) -> XCUIApplication {
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchArguments = ["-PiqMockLibrary", "-PiqMockAccess", access] + (scenario.map { ["-PiqMockScenario", $0] } ?? []) + extra
        app.launch()
        XCUIDevice.shared.orientation = orientation
        Thread.sleep(forTimeInterval: settle)
        // A simulator can get stuck in one orientation (erasing it helps): don't capture
        // "portrait" screenshots of a landscape screen. (Resized windows have their own shape.)
        if fullWidth == nil {
            let window = app.windows.firstMatch.frame
            XCTAssertEqual(
                window.height > window.width, orientation.isPortrait,
                "A \(window.width)×\(window.height) window in \(orientation.isPortrait ? "portrait" : "landscape"): the screen didn't rotate, or a window was left narrow"
            )
        }
        return app
    }

    // MARK: Elements

    func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func labelled(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// Waits until `element`'s label is `label`.
    @discardableResult
    func waitForLabel(_ label: String, of element: XCUIElement, timeout: TimeInterval = 4, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let predicate = NSPredicate(format: "label == %@", label)
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout)
        XCTAssertEqual(result, .completed, "Expected “\(label)”, got “\(element.exists ? element.label : "<missing>")”", file: file, line: line)
        return result == .completed
    }

    /// Waits for the sorting counter ("Photo 38 of 400") and the Review pill ("Review, 4 marked").
    func expectSorting(_ app: XCUIApplication, position: Int, total: Int, marked: Int, file: StaticString = #filePath, line: UInt = #line) {
        let counter = app.staticTexts[ID.counter]
        let review = app.buttons[ID.review]
        let expectedCounter = "Photo \(position) of \(total)"
        let expectedReview = marked > 0 ? "Review, \(marked) marked" : "Review"
        let predicate = NSPredicate { _, _ in
            counter.exists && review.exists && counter.label == expectedCounter && review.label == expectedReview
        }
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 4)
        XCTAssertEqual(
            result, .completed,
            "Expected “\(expectedCounter)” and “\(expectedReview)”, got “\(counter.exists ? counter.label : "-")” and “\(review.exists ? review.label : "-")”",
            file: file, line: line
        )
    }

    /// Waits for a toast that contains `message`. A toast is up for only 2.2 s, so check for it
    /// right after the action that shows it, before waiting on anything else. This looks every
    /// 0.1 s (a predicate expectation looks about once a second, and can miss it under load).
    func expectToast(_ message: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let toast = element(ID.toast, in: app)
        let deadline = Date().addingTimeInterval(5)
        var seen = "none"
        repeat {
            // One query: the toast can go away between an `exists` and a `label`.
            if let snapshot = try? toast.snapshot() {
                seen = snapshot.label
                if snapshot.label.contains(message) { return }
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        XCTFail("No toast saying “\(message)” (toast: “\(seen)”)", file: file, line: line)
    }

    // MARK: Keys

    /// The simulator connects its hardware keyboard on the first key event after a launch and
    /// swallows it: send keys Piq ignores first.
    func wakeKeyboard(_ app: XCUIApplication) {
        for _ in 0..<2 {
            app.windows.firstMatch.typeKey(XCUIKeyboardKey.shift.rawValue, modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.4)
        }
    }

    @nonobjc func press(_ key: XCUIKeyboardKey, _ modifiers: XCUIElement.KeyModifierFlags = [], in app: XCUIApplication) {
        app.windows.firstMatch.typeKey(key, modifierFlags: modifiers)
    }

    @nonobjc func press(_ key: String, _ modifiers: XCUIElement.KeyModifierFlags = [], in app: XCUIApplication) {
        app.windows.firstMatch.typeKey(key, modifierFlags: modifiers)
    }

    func pressReturn(_ app: XCUIApplication) {
        app.windows.firstMatch.typeKey("\n", modifierFlags: [])
    }

    /// Triggers `.keyboardShortcut(.cancelAction)` with ⌘. and waits for `element` to go away.
    /// The simulator drops synthesized keys now and then, so this tries up to three times; an
    /// unwired shortcut fails all three.
    func dismissWithCancelShortcut(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<3 {
            press(".", .command, in: app)
            if element.waitForNonExistence(timeout: 1.5) { return true }
        }
        return false
    }

    // MARK: Windows

    /// Resizes the window to about `width` points with the iPadOS 26 resize grip. A centered
    /// window grows and shrinks symmetrically, so the grip moves half the difference.
    func resizeWindow(_ app: XCUIApplication, toWidth width: CGFloat) {
        if fullWidth == nil {
            let full = app.windows.firstMatch.frame.width
            fullWidth = full
            addTeardownBlock { @MainActor in
                let app = XCUIApplication()
                if app.state != .runningForeground {
                    app.launchArguments = ["-PiqMockLibrary"]
                    app.launch()
                    Thread.sleep(forTimeInterval: 1)
                }
                Self.dragGrip(app, toWidth: full)
                app.terminate()
            }
        }
        Self.dragGrip(app, toWidth: width)
    }

    private static func dragGrip(_ app: XCUIApplication, toWidth width: CGFloat) {
        for _ in 0..<4 {
            let frame = app.windows.firstMatch.frame
            let excess = frame.width - width
            guard abs(excess) > 6 else { return }
            let grip = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.maxX - 4, dy: frame.maxY - 4))
            grip.press(forDuration: 0.6, thenDragTo: grip.withOffset(CGVector(dx: -excess / 2, dy: 0)))
            Thread.sleep(forTimeInterval: 1.2)
        }
    }

    // MARK: Attachments

    /// Attaches a screenshot named `name`-<orientation or width>.
    func shoot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(name)-\(suffix(app))"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Attaches the accessibility hierarchy as text: the elements VoiceOver and the UI tests see.
    func attachHierarchy(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = "\(name)-\(suffix(app))-hierarchy"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// "w600" in a resized window, otherwise the orientation.
    private func suffix(_ app: XCUIApplication) -> String {
        let window = app.windows.firstMatch
        if let fullWidth, window.exists, window.frame.width < fullWidth - 6 {
            return "w\(Int(window.frame.width.rounded()))"
        }
        return XCUIDevice.shared.orientation.isLandscape ? "landscape" : "portrait"
    }
}
