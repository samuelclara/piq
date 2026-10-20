import XCTest

/// Launches the mock-library scenarios in landscape (the designed orientation) and portrait and
/// attaches a screenshot of each, so every screen can be checked without a photo library.
///
///     xcodebuild test -project Piq.xcodeproj -scheme Piq \
///       -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' \
///       -only-testing:PiqUITests/ScreenshotTour -resultBundlePath Tour.xcresult
///     xcrun xcresulttool export attachments --path Tour.xcresult --output-path Screenshots
@MainActor
final class ScreenshotTour: XCTestCase {
    func testAlbumPicker() {
        capture("albums", scenario: "albums")
        capture("albums-resume", scenario: "resume")
        capture("albums-resume", scenario: "resume", orientation: .portrait)
    }

    func testAuthorizationStates() {
        capture("access-limited", scenario: nil, access: "limited")
        capture("access-denied", scenario: nil, access: "denied")
    }

    func testSorting() {
        capture("sorting", scenario: "sorting")
        capture("sorting", scenario: "sorting", orientation: .portrait)
        capture("sorting-loading", scenario: "sorting", extra: ["-PiqMockLatency", "30"], settle: 1)
    }

    func testReview() {
        capture("review-all-sorted", scenario: "review")
        capture("review-partial", scenario: "reviewPartial")
        capture("review-partial", scenario: "reviewPartial", orientation: .portrait)
        capture("review-empty", scenario: "emptyTrash")
    }

    private func capture(
        _ name: String,
        scenario: String?,
        access: String = "authorized",
        orientation: UIDeviceOrientation = .landscapeLeft,
        extra: [String] = [],
        settle: TimeInterval = 2
    ) {
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchArguments = ["-PiqMockLibrary", "-PiqMockAccess", access] + (scenario.map { ["-PiqMockScenario", $0] } ?? []) + extra
        app.launch()
        XCUIDevice.shared.orientation = orientation
        Thread.sleep(forTimeInterval: settle)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(name)-\(orientation.isLandscape ? "landscape" : "portrait")"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
    }
}
