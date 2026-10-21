import SwiftUI
import XCTest
@testable import Piq

/// Renders the sorting screen's Previous and Next states the way its `#Preview`s show them: a
/// revisited photo with its decision tag, the first photo, the end of the album with photos
/// skipped, narrow windows and the largest text. They assert nothing, so they run only when asked:
///
///     TEST_RUNNER_PIQ_SNAPSHOTS=1 xcodebuild test -project Piq.xcodeproj -scheme Piq \
///       -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' \
///       -only-testing:PiqTests/NavigationPreviewSnapshots -resultBundlePath Previews.xcresult
@MainActor
final class NavigationPreviewSnapshots: XCTestCase {
    private enum Size {
        static let landscape = CGSize(width: 1194, height: 834)
        static let portrait = CGSize(width: 834, height: 1194)
        static let narrow = CGSize(width: 600, height: 834)
        static let third = CGSize(width: 380, height: 834)
        static let threshold = CGSize(width: 520, height: 834)
        static let smallest = CGSize(width: 320, height: 834)
    }

    func testRevisitedPhotos() async throws {
        for action in SwipeAction.allCases {
            let (app, session) = PreviewSupport.session(.sorting)
            PreviewSupport.stepBack(session, toPhotoDecided: action)
            try await render("nav-revisit-\(action.rawValue)", Size.landscape) { SortingScreen(session: session).environment(app) }
        }
        let (app, session) = PreviewSupport.session(.sorting)
        PreviewSupport.stepBack(session, toPhotoDecided: .delete)
        try await render("nav-revisit-largest-text", Size.narrow) {
            SortingScreen(session: session).environment(app).dynamicTypeSize(.xxLarge)
        }
        try await render("nav-revisit-third", Size.third) { SortingScreen(session: session).environment(app) }
        try await render("nav-revisit-third-largest-text", Size.third) {
            SortingScreen(session: session).environment(app).dynamicTypeSize(.xxLarge)
        }
        // Where the chevrons fit by the title at the default size, but not at the largest.
        for size in [DynamicTypeSize.large, .xxLarge] {
            try await render("nav-revisit-520-\(size == .large ? "default" : "largest")-text", Size.threshold) {
                SortingScreen(session: session).environment(app).dynamicTypeSize(size)
            }
        }
        try await render("nav-revisit-560-largest-text", CGSize(width: 560, height: 834)) {
            SortingScreen(session: session).environment(app).dynamicTypeSize(.xxLarge)
        }
        try await render("nav-revisit-320-largest-text", Size.smallest) {
            SortingScreen(session: session).environment(app).dynamicTypeSize(.xxLarge)
        }
    }

    func testTheFirstPhotoAndTheEnd() async throws {
        let (startApp, start) = PreviewSupport.session(.sortingStart)
        try await render("nav-first-photo-portrait", Size.portrait) { SortingScreen(session: start).environment(startApp) }
        for (name, size) in [("landscape", Size.landscape), ("third", Size.third)] {
            let (app, session) = PreviewSupport.session(.sorting)
            while session.step(.next) {}
            try await render("nav-end-skipped-\(name)", size) { SortingScreen(session: session).environment(app) }
        }
    }

    private func render<Content: View>(_ name: String, _ size: CGSize, @ViewBuilder content: () -> Content) async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PIQ_SNAPSHOTS"] != nil,
            "Preview snapshots render only with PIQ_SNAPSHOTS set (TEST_RUNNER_PIQ_SNAPSHOTS=1 for xcodebuild)."
        )
        let window = try makeReviewTestWindow(width: size.width, height: size.height) {
            content().preferredColorScheme(.dark)
        }
        defer { window.isHidden = true }
        // Let images and metadata load.
        try await Task.sleep(for: .milliseconds(1200))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "preview-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
