import SwiftUI
import XCTest
@testable import Piq

/// The design system's shared rules: pill padding in whole points, the top bar's centering,
/// VoiceOver's reading of the "·" separators, Increase Contrast and Bold Text.
@MainActor
final class ExperienceDesignSystemTests: XCTestCase {
    // MARK: Pills

    func testPillPaddingIsWholePoints() {
        XCTAssertEqual(PillButtonStyle.horizontalPadding(forHeight: Metrics.minTouch), 20)
        XCTAssertEqual(PillButtonStyle.horizontalPadding(forHeight: Metrics.largeButtonHeight), 25)
        XCTAssertEqual(PillButtonStyle.horizontalPadding(forHeight: 30), 16, "never under 16pt")
        for height in stride(from: 30.0, through: 80.0, by: 0.5) {
            let padding = PillButtonStyle.horizontalPadding(forHeight: height)
            XCTAssertEqual(padding, padding.rounded(), "\(height)pt tall")
        }
    }

    /// Pills are exactly their label plus that padding on each side, so a label's edges stay on
    /// the pixel grid wherever the pill lands.
    func testPillsPadTheirLabelByWholePoints() {
        for label in ["Open Settings", "Change selection", "Select all", "Deselect all", "Restore 50", "Empty trash", "Cancel", "Delete 22 photos", "Try again", "Continue sorting", "Back to albums"] {
            for (height, font) in [(Metrics.minTouch, Font.buttonLabel), (Metrics.largeButtonHeight, Font.largeButtonLabel)] {
                let text = idealWidth(of: Text(label).font(font).lineLimit(1))
                let pill = idealWidth(of: Button(label) {}.buttonStyle(.pill(.secondary, height: height, font: font)))
                XCTAssertEqual(pill, text + 2 * PillButtonStyle.horizontalPadding(forHeight: height), accuracy: 0.001, "“\(label)”, \(height)pt")
            }
        }
    }

    // MARK: Top bar

    private let bar: ClosedRange<CGFloat> = 20...1190

    func testTheTitleIsCenteredWhenItFits() {
        let span = TopBarLayout.centerSpan(in: bar, leadingWidth: 93, trailingWidth: 200, centerWidth: 260, spacing: 12, leadingInset: 0)
        XCTAssertEqual(span.x + span.width / 2, 605, "the middle of the bar")
        XCTAssertEqual(span.width, 260)
    }

    /// A title too wide to be centered moves toward the roomier side, without truncating.
    func testALongTitleMovesAsideBeforeItTruncates() {
        let span = TopBarLayout.centerSpan(in: 20...367, leadingWidth: 160, trailingWidth: 0, centerWidth: 150, spacing: 12, leadingInset: 0)
        XCTAssertEqual(span.x, 192, "right after the back button and the spacing")
        XCTAssertEqual(span.width, 150, "whole")
    }

    func testATitleWiderThanTheGapIsNarrowedToIt() {
        let span = TopBarLayout.centerSpan(in: 20...367, leadingWidth: 160, trailingWidth: 0, centerWidth: 400, spacing: 12, leadingInset: 0)
        XCTAssertEqual(span.x, 192)
        XCTAssertEqual(span.width, 367 - 192 - 12, "the space between the back button and the edge")
    }

    /// iPadOS 26 window controls push the leading side in: the title never ends up under it.
    func testWindowControlsPushTheTitleAside() {
        let inset = Metrics.topBarLeadingInset(clearing: 66)
        XCTAssertEqual(inset, 46)
        XCTAssertEqual(Metrics.topBarLeadingInset(clearing: 0), 0, "full screen: no controls")
        let span = TopBarLayout.centerSpan(in: 20...367, leadingWidth: 160, trailingWidth: 0, centerWidth: 112, spacing: 12, leadingInset: inset)
        XCTAssertGreaterThanOrEqual(span.x, 20 + inset + 160 + 12)
        XCTAssertLessThanOrEqual(span.x + span.width, 367)
    }

    /// Review's back button gives way to the album name: offered only the room the whole name
    /// leaves it, it drops its label (a `ViewThatFits`) before the name truncates.
    func testALeadingSideThatGivesWayLeavesTheCenterWhole() {
        // 387pt window at the largest text: "‹ Continue sorting" 186pt, "Iceland 2026" 131pt,
        // window controls 66pt wide.
        let inset = Metrics.topBarLeadingInset(clearing: 66)
        let offer = TopBarLayout.leadingOffer(idealWidth: 186, barWidth: 347, trailingWidth: 0, centerWidth: 131, spacing: 12, leadingInset: inset, givesWay: true)
        XCTAssertEqual(offer, 347 - inset - 24 - 131)
        let span = TopBarLayout.centerSpan(in: 20...367, leadingWidth: Metrics.minTouch, trailingWidth: 0, centerWidth: 131, spacing: 12, leadingInset: inset)
        XCTAssertEqual(span.width, 131, "the name in full beside the chevron alone")

        XCTAssertEqual(
            TopBarLayout.leadingOffer(idealWidth: 186, barWidth: 1154, trailingWidth: 0, centerWidth: 131, spacing: 12, leadingInset: 0, givesWay: true), 186,
            "all it wants when there's room"
        )
        XCTAssertEqual(
            TopBarLayout.leadingOffer(idealWidth: 93, barWidth: 300, trailingWidth: 200, centerWidth: 260, spacing: 12, leadingInset: 0, givesWay: false), 93,
            "the sorting bar's back button keeps its width (it fits its labels itself)"
        )
        XCTAssertEqual(TopBarLayout.leadingOffer(idealWidth: 186, barWidth: 200, trailingWidth: 0, centerWidth: 400, spacing: 12, leadingInset: 0, givesWay: true), 0)
    }

    // MARK: VoiceOver copy

    func testSeparatorsReadAsPauses() {
        XCTAssertEqual("Start sorting · 400 photos".spoken, "Start sorting, 400 photos")
        XCTAssertEqual("IMG_4838.HEIC · 14:32".spoken, "IMG_4838.HEIC, 14:32")
        XCTAssertEqual("Review".spoken, "Review")
    }

    func testTrashPhotosHaveReadableNames() throws {
        let date = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 12, hour: 14, minute: 32)))
        let metadata = PhotoMetadata(id: "a", filename: "IMG_4838.HEIC", creationDate: date, pixelWidth: 4032, pixelHeight: 3024)
        XCTAssertEqual(ReviewCopy.photoLabel(metadata), "Photo, IMG_4838.HEIC, \(date.formatted(date: .omitted, time: .shortened))")
        XCTAssertEqual(ReviewCopy.photoLabel(nil), "Photo")
    }

    // MARK: Increase Contrast

    func testIncreaseContrastBrightensMutedTextAndHairlines() {
        let regular = UITraitCollection(accessibilityContrast: .normal)
        let high = UITraitCollection(accessibilityContrast: .high)
        XCTAssertEqual(hex(Palette.textMuted, regular), 0xA9A39A)
        XCTAssertEqual(hex(Palette.hairline, regular), 0x2F2C29)
        XCTAssertEqual(hex(Palette.hairlineStrong, regular), 0x3A3733)
        for color in [Palette.textMuted, Palette.hairline, Palette.hairlineStrong] {
            XCTAssertGreaterThan(luminance(hex(color, high)), luminance(hex(color, regular)) * 1.3)
        }
        XCTAssertEqual(hex(Palette.text, high), 0xF4F1EB, "the rest of the palette stays as designed")
    }

    // MARK: Bold Text

    func testBoldTextUsesHeavierFaces() {
        let setting = BoldTextSetting.shared
        let wasOn = setting.isOn
        defer { setting.isOn = wasOn }

        setting.isOn = false
        let regular = [Font.lead, .meta, .buttonLabel, .screenTitle].map { ink(of: Text("Hamburgefonstiv").font($0)) }
        setting.isOn = true
        let bold = [Font.lead, .meta, .buttonLabel, .screenTitle].map { ink(of: Text("Hamburgefonstiv").font($0)) }
        for (index, name) in ["lead", "meta", "buttonLabel", "screenTitle"].enumerated() {
            XCTAssertGreaterThan(Double(bold[index]), Double(regular[index]) * 1.08, name)
        }
    }

    /// Turning Bold Text on re-renders text already on screen.
    func testBoldTextReachesViewsOnScreen() async throws {
        let setting = BoldTextSetting.shared
        let wasOn = setting.isOn
        defer { setting.isOn = wasOn }
        setting.isOn = false
        let window = try makeReviewTestWindow(width: 600, height: 200) {
            BoldTextSample()
        }
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(200))
        let before = ink(of: window)
        setting.isOn = true
        try await Task.sleep(for: .milliseconds(200))
        let after = ink(of: window)
        XCTAssertGreaterThan(Double(after), Double(before) * 1.08)
    }

    // MARK: Helpers

    private func idealWidth(of view: some View) -> CGFloat {
        UIHostingController(rootView: view.fixedSize()).sizeThatFits(in: CGSize(width: 10_000, height: 10_000)).width
    }

    private func hex(_ color: Color, _ traits: UITraitCollection) -> UInt32 {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return UInt32((red * 255).rounded()) << 16 | UInt32((green * 255).rounded()) << 8 | UInt32((blue * 255).rounded())
    }

    private func luminance(_ rgb: UInt32) -> Double {
        func channel(_ value: UInt32) -> Double {
            let c = Double(value) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(rgb >> 16 & 0xFF) + 0.7152 * channel(rgb >> 8 & 0xFF) + 0.0722 * channel(rgb & 0xFF)
    }

    /// Dark pixels of `view` rendered black on white.
    private func ink(of view: some View) -> Int {
        let renderer = ImageRenderer(content: view.foregroundStyle(.black).padding(4).background(.white))
        renderer.scale = 2
        return renderer.cgImage.map(darkPixels) ?? 0
    }

    private func ink(of window: UIWindow) -> Int {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        return image.cgImage.map(darkPixels) ?? 0
    }

    private func darkPixels(_ image: CGImage) -> Int {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] < 128 }.count
    }
}

/// Copy in the type scale, black on white, for measuring how heavy it renders.
private struct BoldTextSample: View {
    var body: some View {
        VStack(alignment: .leading) {
            Text("Which album are we sorting?").font(.screenTitle)
            Text("Piq shows each photo full screen.").font(.lead)
        }
        .foregroundStyle(.black)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white)
    }
}
