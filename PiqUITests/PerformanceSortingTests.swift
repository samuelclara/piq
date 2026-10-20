import OSLog
import XCTest

/// Piq on a real photo library: opening Recents, sorting at a steady pace and in bursts, and the
/// review grid with about 100 marked photos. Records memory, time and the image-request signposts
/// (`XCTMemoryMetric`, `XCTClockMetric`, `XCTOSSignpostMetric`) and marks each phase and key press
/// with "io.belleville.piq.perf" signposts, so a host-side `log stream --signpost` can line them up
/// with the app's own "io.belleville.piq"/"images" signposts.
///
/// Gated: runs only with `TEST_RUNNER_PIQ_E2E=1`, on a simulator prepared once with a library of
/// 400+ full-resolution photos:
///
///     # ~450 photos: 12 MP JPEG (3.4-4.9 MB) and HEIC, ten at 48 MP, distinct capture dates over
///     # three days, made by Tools/Performance/genlibrary.swift and imported by its
///     # prepare-library.sh; any 400+ camera photos imported with `simctl addmedia` do.
///     Tools/Performance/prepare-library.sh <SIM> <repo> <out-dir> all     # generate, import, grant, reset
///     Tools/Performance/prepare-library.sh <SIM> <repo> <out-dir> reset   # before each run: Recents starts fresh
///
///     TEST_RUNNER_PIQ_E2E=1 xcodebuild test -project Piq.xcodeproj -scheme Piq \
///       -destination "platform=iOS Simulator,id=<SIM>" -only-testing:PiqUITests/PerformanceSortingTests
///
/// `simctl privacy grant photos` doesn't satisfy PhotoKit on iOS 26 simulators, so the first
/// launch taps "Allow Full Access" on the system prompt. That also gives the hosted
/// `PerformanceRealLibraryTests` their access: on a fresh simulator, run this class first.
///
/// The tests run in order and share the Recents session that the app saves: the first starts it,
/// the next ones resume it (a full run sorts about 290 photos). XCTest runs each measured block
/// twice, once to warm up, so each phase happens twice. `TEST_RUNNER_PIQ_PERF_STEADY` sets how
/// many photos each steady block sorts (default 75), and `TEST_RUNNER_PIQ_PERF_MALLOC_STACKS=1`
/// launches the app with `MallocStackLogging`, for `leaks` to attribute what it finds.
@MainActor
final class PerformanceSortingTests: XCTestCase {
    private enum ID {
        static let start = "picker.start"
        static let recents = "picker.album.Recents"
        static let counter = "sorting.counter"
        static let photo = "sorting.photo"
        static let review = "sorting.review"
        static let reviewBack = "review.back"
        static let closePreview = "review.closePreview"
        static let tilePrefix = "review.tile."
    }

    /// Marks phases and key presses for the host-side analysis.
    private let driver = OSSignposter(subsystem: "io.belleville.piq.perf", category: "driver")

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PIQ_E2E"] == "1",
            "Needs a simulator with a prepared photo library: run with TEST_RUNNER_PIQ_E2E=1"
        )
        continueAfterFailure = false
    }

    /// Start (or resume) Recents and sort one photo every 0.6 s, deleting 1 in 8; then drag a
    /// dozen photos off by hand.
    func test1SteadyPace() throws {
        let app = launch()
        try openRecents(app)
        let count = Int(ProcessInfo.processInfo.environment["PIQ_PERF_STEADY"] ?? "") ?? 75
        let options = XCTMeasureOptions()
        options.iterationCount = 1
        measure(metrics: Self.sortingMetrics(app), options: options) {
            mark("steady begin")
            let start = Date()
            for index in 0..<count {
                decide(app, delete: index % 8 == 7)
                let next = start.addingTimeInterval(0.6 * Double(index + 1))
                let wait = next.timeIntervalSinceNow
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            }
            mark("steady end")
        }
        settle()
        attachScreenshot("sorting-real-library")

        // Drags: the photo follows the finger past the threshold, is held, and is let go.
        let photo = app.descendants(matching: .any)[ID.photo]
        mark("drags begin")
        for index in 0..<12 {
            let start = photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let end = start.withOffset(CGVector(dx: index.isMultiple(of: 2) ? 220 : -220, dy: 18))
            mark("key drag")
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.15)
            Thread.sleep(forTimeInterval: 0.4)
        }
        mark("drags end")
        settle()
    }

    /// Bursts of five decisions, back to back (as fast as XCUITest sends keys: about one every
    /// 0.45 s), with a 1.5 s pause between bursts. `PerformanceRealLibraryTests` drives the
    /// loader faster: five decisions within a second, and a held arrow key.
    func test2Bursts() throws {
        let app = launch()
        try openRecents(app)
        let options = XCTMeasureOptions()
        options.iterationCount = 1
        measure(metrics: Self.sortingMetrics(app), options: options) {
            mark("bursts begin")
            for burst in 0..<5 {
                mark("burst \(burst)")
                for index in 0..<5 {
                    decide(app, delete: index == 2)
                }
                Thread.sleep(forTimeInterval: 1.5)
            }
            mark("bursts end")
        }
        settle()
    }

    /// Marks photos until about 100 are in the trash, then scrolls the review grid and opens and
    /// closes the full-screen preview five times (each twice: see above).
    func test3ReviewWithManyMarked() throws {
        let app = launch()
        try openRecents(app)
        let review = app.buttons[ID.review]
        let back = app.buttons[ID.reviewBack]
        mark("marking begin")
        // Until about 100 photos are marked, or the album runs out (Piq then opens Review itself).
        while review.exists, markedCount(review) < 100 {
            decide(app, delete: true)
            Thread.sleep(forTimeInterval: 0.3)
        }
        mark("marking end")
        settle()
        if !back.exists {
            review.tap()
        }
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Review is up")
        Thread.sleep(forTimeInterval: 2)
        attachScreenshot("review-real-library")

        let grid = app.scrollViews.firstMatch
        let tiles = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", ID.tilePrefix))
        let options = XCTMeasureOptions()
        options.iterationCount = 1
        measure(metrics: [XCTMemoryMetric(application: app), XCTClockMetric(), XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            mark("scroll begin")
            for _ in 0..<3 {
                for _ in 0..<4 { grid.swipeUp(velocity: .fast) }
                for _ in 0..<4 { grid.swipeDown(velocity: .fast) }
            }
            mark("scroll end")
            mark("previews begin")
            for index in 0..<5 {
                let tile = tiles.element(boundBy: index % 6)
                tile.press(forDuration: 0.5)
                let close = app.buttons[ID.closePreview]
                XCTAssertTrue(close.waitForExistence(timeout: 3), "The preview opens")
                Thread.sleep(forTimeInterval: 1.2)
                close.tap()
                if !close.waitForNonExistence(timeout: 3) {
                    // On this loaded simulator a synthesized tap is now and then lost (about 1 in
                    // 50 here); the measurement goes on, and the attachment says so.
                    let note = XCTAttachment(string: "Close tap \(index + 1) lost; tapped again")
                    note.lifetime = .keepAlways
                    add(note)
                    close.tap()
                }
                XCTAssertTrue(close.waitForNonExistence(timeout: 3), "The preview closes")
                Thread.sleep(forTimeInterval: 0.6)
            }
            mark("previews end")
        }
        // Tiles flung past without loading load once the grid comes to rest.
        for _ in 0..<4 { grid.swipeUp(velocity: .fast) }
        Thread.sleep(forTimeInterval: 1.5)
        attachScreenshot("review-real-library-scrolled")
        app.buttons[ID.reviewBack].tap()
        settle()
    }

    // MARK: Helpers

    private static func sortingMetrics(_ app: XCUIApplication) -> [XCTMetric] {
        [
            XCTMemoryMetric(application: app),
            XCTClockMetric(),
            XCTOSSignpostMetric(subsystem: "io.belleville.piq", category: "images", name: "Full image"),
            XCTOSSignpostMetric(subsystem: "io.belleville.piq", category: "images", name: "Preview"),
        ]
    }

    private func launch() -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        if ProcessInfo.processInfo.environment["PIQ_PERF_MALLOC_STACKS"] == "1" {
            // So that `leaks` on the app can say where each leaked block was allocated.
            app.launchEnvironment["MallocStackLogging"] = "1"
        }
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        mark("launched")
        allowPhotosAccessIfAsked(app)
        return app
    }

    /// `simctl privacy grant photos` doesn't satisfy PhotoKit on iOS 26 simulators, so the
    /// system prompt can show on the first launch: allow full access there.
    private func allowPhotosAccessIfAsked(_ app: XCUIApplication) {
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Full Access"]
        let listed = app.buttons[ID.recents]
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, !listed.exists {
            if allow.exists {
                allow.tap()
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    /// Selects Recents once its tile shows a count, starts or resumes it, and waits for the photo.
    private func openRecents(_ app: XCUIApplication) throws {
        let tile = app.buttons[ID.recents]
        XCTAssertTrue(tile.waitForExistence(timeout: 20), "Recents is listed")
        mark("albums listed \(tile.label)")
        tile.tap()
        let start = app.buttons[ID.start]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        if start.label.hasPrefix("Review") {
            throw XCTSkip("Recents is fully sorted: reset the session store (prepare-library.sh reset)")
        }
        mark("tap start \(start.label)")
        start.tap()
        let counter = app.staticTexts[ID.counter]
        XCTAssertTrue(counter.waitForExistence(timeout: 20), "Sorting is up")
        mark("sorting up \(counter.label)")
        // The first synthesized key after launch is swallowed: wake the keyboard with Shift.
        Thread.sleep(forTimeInterval: 1.5)
        for _ in 0..<2 {
            app.windows.firstMatch.typeKey(XCUIKeyboardKey.shift.rawValue, modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.5)
        }
        mark("ready")
    }

    private func decide(_ app: XCUIApplication, delete: Bool) {
        mark(delete ? "key left" : "key right")
        app.windows.firstMatch.typeKey(delete ? .leftArrow : .rightArrow, modifierFlags: [])
    }

    /// "Review, 12 marked" -> 12; "Review" -> 0.
    private func markedCount(_ review: XCUIElement) -> Int {
        Int(review.label.filter(\.isNumber)) ?? 0
    }

    /// Lets the last flight land and the session save before the next step.
    private func settle() {
        Thread.sleep(forTimeInterval: 1.5)
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func mark(_ message: String) {
        driver.emitEvent("Driver", "\(message, privacy: .public)")
    }
}
