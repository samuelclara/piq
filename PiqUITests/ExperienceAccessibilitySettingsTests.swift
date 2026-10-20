import XCTest

/// Piq under Bold Text, Increase Contrast and Reduce Motion: a short walk through every screen
/// with each setting on (sorting with a swipe, the pills and the keys, Review with a selection,
/// the confirmation and the preview), checking the flow still works and attaching screenshots.
///
/// It switches the settings in the Settings app (Accessibility › Display & Text Size, and
/// Accessibility › Motion) and switches them back off when it ends, so it runs only when asked:
///
///     TEST_RUNNER_PIQ_A11Y_SETTINGS=1 xcodebuild test -project Piq.xcodeproj -scheme Piq \
///       -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' \
///       -only-testing:PiqUITests/ExperienceAccessibilitySettingsTests
@MainActor
final class ExperienceAccessibilitySettingsTests: ExperienceTestCase {
    private enum Setting: String {
        case boldText = "Bold Text"
        case increaseContrast = "Increase Contrast"
        case reduceMotion = "Reduce Motion"

        /// The Accessibility page the switch is on.
        var page: String {
            self == .reduceMotion ? "Motion" : "Display & Text Size"
        }
    }

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PIQ_A11Y_SETTINGS"] == "1",
            "Changes accessibility settings: runs only with PIQ_A11Y_SETTINGS=1."
        )
    }

    func testBoldText() {
        walk(with: .boldText)
    }

    func testIncreaseContrast() {
        walk(with: .increaseContrast)
    }

    func testReduceMotion() {
        walk(with: .reduceMotion)
    }

    // MARK: Walk

    private func walk(with setting: Setting) {
        set(setting, on: true)
        addTeardownBlock { @MainActor in
            self.set(setting, on: false)
        }
        let name = setting.rawValue.lowercased().replacingOccurrences(of: " ", with: "-")

        var app = launch(scenario: "resume")
        shoot("\(name)-picker", app)
        app.buttons[ID.start].tap()
        expectSorting(app, position: 38, total: 400, marked: 4)
        element(ID.photo, in: app).swipeLeft()
        // The toast first: it's up for 2.2 seconds from the swipe.
        expectToast("Marked for deletion", in: app)
        shoot("\(name)-sorting", app)
        expectSorting(app, position: 39, total: 400, marked: 5)
        app.buttons[ID.keep].tap()
        expectSorting(app, position: 40, total: 400, marked: 5)
        wakeKeyboard(app)
        press(.leftArrow, in: app)
        expectSorting(app, position: 41, total: 400, marked: 6)
        press("z", .command, in: app)
        expectSorting(app, position: 40, total: 400, marked: 5)

        app.buttons[ID.review].tap()
        XCTAssertTrue(element(ID.summary, in: app).waitForExistence(timeout: 4))
        element(ID.tile("mock-asset-0011"), in: app).tap()
        Thread.sleep(forTimeInterval: 0.5)
        shoot("\(name)-review", app)
        app.buttons[ID.emptyTrash].tap()
        XCTAssertTrue(app.buttons[ID.confirmDelete].waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 0.6)
        shoot("\(name)-confirm", app)
        app.buttons[ID.cancelDelete].tap()
        XCTAssertTrue(app.buttons[ID.confirmDelete].waitForNonExistence(timeout: 3))
        element(ID.tile("mock-asset-0011"), in: app).press(forDuration: 0.5)
        XCTAssertTrue(app.buttons[ID.closePreview].waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 1)
        shoot("\(name)-preview", app)
        app.buttons[ID.closePreview].tap()
        app.terminate()

        app = launch(access: "denied")
        shoot("\(name)-denied", app)
        app.terminate()
    }

    // MARK: Settings

    /// Turns `setting` on or off in the Settings app.
    private func set(_ setting: Setting, on: Bool) {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        let any = settings.descendants(matching: .any)
        for label in ["Accessibility", setting.page] {
            let row = any.matching(NSPredicate(format: "label == %@", label)).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5), "No “\(label)” in Settings")
            row.tap()
        }
        let row = settings.switches.matching(NSPredicate(format: "label == %@", setting.rawValue)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "No “\(setting.rawValue)” switch")
        // The row is a switch holding the switch that toggles; either may carry the value.
        let knob = row.switches.allElementsBoundByIndex.last ?? row
        func isOn() -> Bool {
            [row, knob].compactMap { $0.value as? String }.contains("1")
        }
        if isOn() != on {
            knob.tap()
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertEqual(isOn(), on, "\(setting.rawValue) is \(on ? "on" : "off")")
        settings.terminate()
    }
}
