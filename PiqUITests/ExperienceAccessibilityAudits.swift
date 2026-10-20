import XCTest

/// Runs Xcode's accessibility audit (contrast, element detection, hit regions, descriptions,
/// Dynamic Type, clipped text, traits) on every screen and state of the app, on the mock
/// library, and fails on any issue that isn't a known, verified false positive (see
/// `falsePositive(_:in:)`). Each audit attaches its findings, the false positives with the reason
/// they were let through, and a screenshot.
@MainActor
final class ExperienceAccessibilityAudits: ExperienceTestCase {
    func testPicker() throws {
        var app = launch(scenario: "albums")
        try audit("picker", app)
        app.buttons[ID.album("Iceland 2026")].tap()
        try audit("picker-selected", app)
        app.terminate()

        app = launch(scenario: "resume")
        try audit("picker-resume", app)
        app.terminate()

        for access in ["limited", "denied", "restricted"] {
            app = launch(access: access)
            try audit("picker-\(access)", app)
            app.terminate()
        }
    }

    func testSorting() throws {
        var app = launch(scenario: "sorting")
        XCTAssertTrue(app.staticTexts[ID.counter].waitForExistence(timeout: 4))
        try audit("sorting", app)
        app.buttons[ID.delete].tap()
        expectToast("Marked for deletion", in: app)
        try audit("sorting-toast", app)
        app.terminate()

        // A photo still downloading from iCloud (the mock takes 30s for each sharp image).
        app = launch(scenario: "sorting", extra: ["-PiqMockLatency", "30"])
        try audit("sorting-downloading", app)
        app.terminate()
    }

    /// The photo's element is the photo at rest, whatever its shape and the next photo's, so
    /// VoiceOver's outline and Full Keyboard Access's ring sit on it and touch exploration finds
    /// Delete and Keep under it. In "Iceland 2026", photo 42 is landscape with a portrait photo
    /// next (the card behind fills the photo's frame with it), and 43 is that portrait photo.
    func testSortingPhotoElementIsThePhoto() throws {
        let app = launch(scenario: "sorting")
        expectSorting(app, position: 38, total: 400, marked: 4)
        for position in 39...42 {
            app.buttons[ID.keep].tap()
            expectSorting(app, position: position, total: 400, marked: 4)
        }
        Thread.sleep(forTimeInterval: 1)
        expectPhotoElement(aspectRatio: 3.0 / 2, in: app, "42, a portrait photo next")
        try audit("sorting-portrait-next", app)

        app.buttons[ID.keep].tap()
        expectSorting(app, position: 43, total: 400, marked: 4)
        Thread.sleep(forTimeInterval: 1)
        expectPhotoElement(aspectRatio: 2.0 / 3, in: app, "43, portrait")
        try audit("sorting-portrait", app)

        app.buttons[ID.keep].tap()
        expectSorting(app, position: 44, total: 400, marked: 4)
        app.buttons[ID.undo].tap()
        expectSorting(app, position: 43, total: 400, marked: 4)
        Thread.sleep(forTimeInterval: 1)
        expectPhotoElement(aspectRatio: 2.0 / 3, in: app, "43 again, after Undo")
        app.terminate()
    }

    /// The last photo leads to Review on its own: the screen as it arrives there.
    func testSortingComplete() throws {
        let app = launch(scenario: "albums")
        app.buttons[ID.album("Family")].tap()
        app.buttons[ID.start].tap()
        expectSorting(app, position: 1, total: 18, marked: 0)
        Thread.sleep(forTimeInterval: 1)
        for _ in 0..<18 {
            app.buttons[ID.keep].tap()
        }
        XCTAssertTrue(element(ID.emptyState, in: app).waitForExistence(timeout: 4), "Sorting the last photo opens Review")
        Thread.sleep(forTimeInterval: 1)
        try audit("sorting-complete", app)
        app.terminate()
    }

    func testReview() throws {
        var app = launch(scenario: "review")
        try audit("review", app)
        element(ID.tile("mock-asset-0011"), in: app).tap()
        try audit("review-selection", app)
        app.buttons[ID.emptyTrash].tap()
        XCTAssertTrue(app.buttons[ID.confirmDelete].waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 0.6)
        try audit("review-confirm", app)
        app.buttons[ID.cancelDelete].tap()
        XCTAssertTrue(app.buttons[ID.confirmDelete].waitForNonExistence(timeout: 3))
        element(ID.tile("mock-asset-0025"), in: app).press(forDuration: 0.5)
        XCTAssertTrue(app.buttons[ID.closePreview].waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 1)
        try audit("review-preview", app)
        app.terminate()

        app = launch(scenario: "reviewPartial")
        try audit("review-partial", app)
        app.terminate()

        app = launch(scenario: "emptyTrash")
        try audit("review-empty", app)
        app.terminate()
    }

    /// The photo element has the photo's shape, centered on the stage between the top bar and
    /// the pills, and it and the pills under it can be found by touch.
    private func expectPhotoElement(aspectRatio: CGFloat, in app: XCUIApplication, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let photo = element(ID.photo, in: app)
        let delete = app.buttons[ID.delete]
        let keep = app.buttons[ID.keep]
        let frame = photo.frame
        let window = app.windows.firstMatch.frame
        let counter = app.staticTexts[ID.counter].frame
        XCTAssertEqual(frame.width / max(frame.height, 1), aspectRatio, accuracy: 0.01, "\(name): \(frame) has the photo's shape", file: file, line: line)
        XCTAssertEqual(frame.midX, window.midX, accuracy: 1, "\(name): centered", file: file, line: line)
        XCTAssertGreaterThan(frame.minY, counter.maxY, "\(name): under the top bar", file: file, line: line)
        XCTAssertLessThan(frame.maxY, min(delete.frame.minY, keep.frame.minY), "\(name): above Delete and Keep", file: file, line: line)
        XCTAssertTrue(photo.isHittable, "\(name): the photo can be found by touch", file: file, line: line)
        XCTAssertTrue(delete.isHittable, "\(name): Delete can be found by touch", file: file, line: line)
        XCTAssertTrue(keep.isHittable, "\(name): Keep can be found by touch", file: file, line: line)
    }

    // MARK: Auditing

    /// Audits the screen as it is, failing on every issue `falsePositive(_:in:)` doesn't explain.
    private func audit(_ name: String, _ app: XCUIApplication) throws {
        var report: [String] = []
        try app.performAccessibilityAudit { issue in
            let reason = self.falsePositive(issue, in: app)
            report.append("\(reason == nil ? "ISSUE" : "ignored") \(Self.describe(issue))\(reason.map { " — \($0)" } ?? "")")
            return reason != nil
        }
        let attachment = XCTAttachment(string: report.isEmpty ? "No issues" : report.joined(separator: "\n"))
        attachment.name = "audit-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        shoot("audit-\(name)", app)
    }

    /// Why `issue` is a false positive, or nil when it is a real issue. Each rule was checked
    /// against the running app; the comments say how.
    private func falsePositive(_ issue: XCUIAccessibilityAuditIssue, in app: XCUIApplication) -> String? {
        let element = issue.element
        switch issue.auditType {
        case .dynamicType where issue.compactDescription.localizedCaseInsensitiveContains("partially"):
            // The root caps Dynamic Type at xxLarge (`RootView`); the text scales up to that cap
            // and the audit flags it for not growing into the accessibility sizes past it.
            // Without the cap these issues go away (70 to 9 on the picker states).
            return "text stops growing at the app's xxLarge Dynamic Type cap"
        case .contrast:
            guard let element else { return nil }
            if !element.isEnabled {
                // Inactive controls are exempt (WCAG 1.4.3); the dimming is how they read as
                // unavailable.
                return "disabled control"
            }
            let card = app.alerts.firstMatch
            if card.exists, !card.frame.contains(element.frame) {
                // The confirmation's 60% backdrop dims the screen under it on purpose, and that
                // screen is hidden from VoiceOver while the card is up.
                return "dimmed under the modal card"
            }
            if Self.isBehindCardChip(element, in: app) {
                // The card behind the current photo keeps its chip at opacity 0 so the chip can
                // fade in when the card comes forward; it's hidden from VoiceOver, but XCUITest
                // still lists it.
                return "invisible chip of the card behind the current photo"
            }
            if let measured = Self.measuredContrast(of: element), measured >= 4.5 {
                // The audit misjudges some text: the small count badge, and the confirmation
                // card's own text, which it rates as if it were under the card's backdrop.
                return String(format: "measured %.1f:1 in the screenshot", measured)
            }
            return nil
        case .elementDetection where element == nil && app.alerts.firstMatch.exists:
            // Text recognition reads the dimmed tiles the confirmation card partly covers
            // ("4442.HEIC") and can't match them to their elements, hidden while the card is up.
            return "text under the modal card"
        default:
            return nil
        }
    }

    /// A chip inside the sorting photo that doesn't name the current photo.
    private static func isBehindCardChip(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let photo = app.descendants(matching: .any)[ID.photo]
        guard element.elementType == .staticText, photo.exists, photo.frame.contains(element.frame),
              let filename = element.label.components(separatedBy: " · ").first else { return false }
        return !photo.label.contains(filename)
    }

    /// The WCAG contrast ratio of the text in `element`'s screenshot: its most common color is
    /// the background, and the color farthest from it in luminance is the text.
    private static func measuredContrast(of element: XCUIElement) -> Double? {
        guard let image = element.screenshot().image.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var counts: [UInt32: Int] = [:]
        for index in stride(from: 0, to: pixels.count, by: 4) {
            counts[UInt32(pixels[index]) << 16 | UInt32(pixels[index + 1]) << 8 | UInt32(pixels[index + 2]), default: 0] += 1
        }
        guard let background = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        let backgroundLuminance = luminance(background)
        let text = counts.keys.max { abs(luminance($0) - backgroundLuminance) < abs(luminance($1) - backgroundLuminance) } ?? background
        let light = max(luminance(text), backgroundLuminance)
        let dark = min(luminance(text), backgroundLuminance)
        return (light + 0.05) / (dark + 0.05)
    }

    /// Relative luminance (WCAG) of a 0xRRGGBB sRGB color.
    private static func luminance(_ rgb: UInt32) -> Double {
        func channel(_ value: UInt32) -> Double {
            let c = Double(value) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(rgb >> 16 & 0xFF) + 0.7152 * channel(rgb >> 8 & 0xFF) + 0.0722 * channel(rgb & 0xFF)
    }

    private static func describe(_ issue: XCUIAccessibilityAuditIssue) -> String {
        let type = switch issue.auditType {
        case .contrast: "contrast"
        case .elementDetection: "elementDetection"
        case .hitRegion: "hitRegion"
        case .sufficientElementDescription: "sufficientElementDescription"
        case .dynamicType: "dynamicType"
        case .textClipped: "textClipped"
        case .trait: "trait"
        default: "type \(issue.auditType.rawValue)"
        }
        let element = issue.element.map { "id='\($0.identifier)' label='\($0.label)' frame=\($0.frame)" } ?? "no element"
        return "\(type): \(issue.compactDescription) | \(element)"
    }
}
