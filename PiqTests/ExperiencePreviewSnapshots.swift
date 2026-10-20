import SwiftUI
import XCTest
@testable import Piq

/// Renders what the screens' `#Preview`s show, from the same `PreviewSupport` scenarios and at the
/// same sizes (landscape 1194×834, portrait 834×1194, a 600pt window, the largest text), and
/// attaches the images to look at. They assert nothing, so they run only when asked:
///
///     TEST_RUNNER_PIQ_SNAPSHOTS=1 xcodebuild test -project Piq.xcodeproj -scheme Piq \
///       -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' \
///       -only-testing:PiqTests/ExperiencePreviewSnapshots -resultBundlePath Previews.xcresult
@MainActor
final class ExperiencePreviewSnapshots: XCTestCase {
    private enum Size {
        static let landscape = CGSize(width: 1194, height: 834)
        static let portrait = CGSize(width: 834, height: 1194)
        static let narrow = CGSize(width: 600, height: 834)
    }

    func testAlbumPicker() async throws {
        try await render("picker-albums", Size.landscape) { AlbumPickerScreen().environment(PreviewSupport.appModel(.albums)) }
        try await render("picker-resume", Size.landscape) { AlbumPickerScreen().environment(PreviewSupport.appModel(.resume)) }
        try await render("picker-review", Size.landscape) { AlbumPickerScreen().environment(PreviewSupport.appModel(.review)) }
        for access in [LibraryAccess.limited, .denied, .restricted] {
            try await render("picker-\(access.rawValue)", Size.landscape) {
                AlbumPickerScreen().environment(PreviewSupport.appModel(.albums, access: access))
            }
        }
        try await render("picker-waiting", Size.landscape) { AlbumPickerScreen().environment(PreviewSupport.appModel(nil, access: .notDetermined)) }
        try await render("picker-portrait", Size.portrait) { AlbumPickerScreen().environment(PreviewSupport.appModel(.resume)) }
        try await render("picker-narrow", Size.narrow) { AlbumPickerScreen().environment(PreviewSupport.appModel(.resume)) }
        try await render("picker-largest-text", Size.narrow) {
            AlbumPickerScreen().environment(PreviewSupport.appModel(.resume)).dynamicTypeSize(.xxLarge)
        }
    }

    func testSorting() async throws {
        for (name, size) in [("landscape", Size.landscape), ("portrait", Size.portrait), ("narrow", Size.narrow)] {
            let (app, session) = PreviewSupport.session(.sorting)
            try await render("sorting-\(name)", size) { SortingScreen(session: session).environment(app) }
        }
        let (app, session) = PreviewSupport.session(.sorting)
        try await render("sorting-swiping-left", Size.landscape) {
            SortingScreen(session: session, previewDrag: CGSize(width: -150, height: 12)).environment(app)
        }
        let (doneApp, done) = PreviewSupport.session(.review)
        try await render("sorting-all-sorted", Size.landscape) { SortingScreen(session: done).environment(doneApp) }
        let (largeApp, large) = PreviewSupport.session(.sorting)
        try await render("sorting-largest-text", Size.narrow) {
            SortingScreen(session: large).environment(largeApp).dynamicTypeSize(.xxLarge)
        }
    }

    func testReview() async throws {
        for (name, scenario) in [("all-sorted", PreviewSupport.Scenario.review), ("partial", .reviewPartial), ("empty", .emptyTrash)] {
            let (app, session) = PreviewSupport.session(scenario)
            try await render("review-\(name)", Size.landscape) { ReviewScreen(session: session).environment(app) }
        }
        let (app, session) = PreviewSupport.session(.review)
        let selection = Set(session.state.markedInOrder.prefix(3))
        try await render("review-selection", Size.landscape) { ReviewScreen(session: session, selection: selection).environment(app) }
        try await render("review-confirm", Size.landscape) {
            ReviewScreen(session: session, selection: [], confirmingDelete: true).environment(app)
        }
        try await render("review-portrait", Size.portrait) { ReviewScreen(session: session).environment(app) }
        try await render("review-narrow", Size.narrow) { ReviewScreen(session: session).environment(app) }
        try await render("review-largest-text", Size.narrow) {
            ReviewScreen(session: session, selection: Set(session.state.markedInOrder.prefix(2))).environment(app).dynamicTypeSize(.xxLarge)
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
