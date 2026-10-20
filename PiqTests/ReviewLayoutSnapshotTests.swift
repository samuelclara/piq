import SwiftUI
import XCTest
@testable import Piq

/// Renders the review screen into windows and attaches the images, to look at: the Split View and
/// Slide Over widths a UI test can't resize the simulator to, long album names, the largest text
/// size, a full-size image that fails to load, and the moment Photos is asked to delete. They
/// assert nothing (`ReviewLayoutTests` has the rules), so they run only when asked:
///
///     TEST_RUNNER_PIQ_SNAPSHOTS=1 xcodebuild test -project Piq.xcodeproj -scheme Piq \
///       -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' \
///       -only-testing:PiqTests/ReviewLayoutSnapshotTests -resultBundlePath Layouts.xcresult
@MainActor
final class ReviewLayoutSnapshotTests: XCTestCase {
    private let height: CGFloat = 834

    func testTrash() async throws {
        for width in [600, 507, 500, 375] as [CGFloat] {
            let (app, session) = PreviewSupport.session(.review)
            let selection = Set(session.state.markedInOrder.prefix(2))
            try await render("review-\(Int(width))", width: width) {
                ReviewScreen(session: session, selection: selection).environment(app)
            }
        }
    }

    func testConfirmation() async throws {
        for width in [1194, 600, 375] as [CGFloat] {
            let (app, session) = PreviewSupport.session(.review)
            try await render("review-confirm-\(Int(width))", width: width) {
                ReviewScreen(session: session, selection: [], confirmingDelete: true).environment(app)
            }
        }
    }

    func testEmptyTrash() async throws {
        for width in [600, 375] as [CGFloat] {
            let (app, session) = PreviewSupport.session(.emptyTrash)
            try await render("review-empty-\(Int(width))", width: width) {
                ReviewScreen(session: session).environment(app)
            }
        }
    }

    /// The largest text size the app allows (the root caps Dynamic Type at xxLarge).
    func testLargestText() async throws {
        for width in [1194, 600, 375] as [CGFloat] {
            let (app, session) = PreviewSupport.session(.review)
            try await render("review-xxl-\(Int(width))", width: width) {
                ReviewScreen(session: session)
                    .environment(app)
                    .dynamicTypeSize(.xxLarge)
            }
        }
    }

    /// The top bar at each width, for short to very long album names, at the default and the
    /// largest text size.
    func testTopBar() async throws {
        let names = ["Iceland 2026", "Weekend in Lisbon", "Summer holidays in Brittany with the whole family, August 2026"]
        let widths: [CGFloat] = [1194, 834, 600, 507, 375]
        for size in [DynamicTypeSize.large, .xxLarge] {
            try await render("review-topbar-\(size == .large ? "default" : "xxl")", width: 1194, height: CGFloat(names.count * widths.count * 2) * 84) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(names, id: \.self) { name in
                        ForEach(["Continue sorting", "Albums"], id: \.self) { back in
                            ForEach(widths, id: \.self) { width in
                                ReviewTopBar(albumTitle: name, backTitle: back) {}
                                    .frame(width: width)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(hex: 0x3A3733))
                .dynamicTypeSize(size)
            }
        }
    }

    /// The section header where its actions wrap, with nothing, one photo and everything selected:
    /// each width keeps one layout.
    func testSectionHeaderWidths() async throws {
        let widths: [CGFloat] = [358, 368, 378, 388, 398]
        try await render("review-section-widths", width: 1260, height: CGFloat(widths.count) * 180) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(widths, id: \.self) { width in
                    HStack(alignment: .top, spacing: 10) {
                        ForEach([0, 1, 50], id: \.self) { selected in
                            TrashSectionHeader(
                                trashCount: 50,
                                selectedCount: selected,
                                isEverythingSelected: selected == 50,
                                isEmptyingTrash: false,
                                toggleSelectAll: {},
                                restore: {},
                                emptyTrash: {}
                            )
                            .frame(width: width)
                            .background(Palette.ground)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(hex: 0x3A3733))
        }
    }

    /// The full-screen preview when the sharp image can't be loaded: over the quick preview, and
    /// with no image at all.
    func testPreviewThatFailsToLoad() async throws {
        for (name, failsPreview) in [("preview-failed", false), ("preview-failed-no-image", true)] {
            for width in [1194, 375] as [CGFloat] {
                let base = PreviewSupport.appModel(.review)
                let assetID = try XCTUnwrap(base.activeSession?.state.markedInOrder[1])
                let images = StubImageSource(base: base.images)
                images.failsFullImage = true
                images.failsPreview = failsPreview
                let app = AppModel.reviewTest(sharingLibraryOf: base, images: images)
                try await render("review-\(name)-\(Int(width))", width: width) {
                    ReviewPhotoPreview(assetID: assetID, metadata: nil).environment(app)
                }
            }
        }
    }

    /// The Empty trash button while Photos is asked to delete (the mock answers after 350ms).
    func testEmptying() async throws {
        let (app, session) = PreviewSupport.session(.review)
        let selection = Set(session.state.markedInOrder.prefix(2))
        var deletion: Task<Void, Never>?
        try await render("review-emptying", width: 1194) {
            ReviewScreen(session: session, selection: selection).environment(app)
        } beforeCapture: {
            deletion = Task { _ = await session.emptyTrash() }
            try? await Task.sleep(for: .milliseconds(150))
        }
        // Let it finish while the app model, and so the session store, is still alive.
        await deletion?.value
        withExtendedLifetime(app) {}
    }

    private func render<Content: View>(
        _ name: String,
        width: CGFloat,
        height: CGFloat? = nil,
        @ViewBuilder content: () -> Content,
        beforeCapture: () async -> Void = {}
    ) async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PIQ_SNAPSHOTS"] != nil,
            "Layout snapshots render only with PIQ_SNAPSHOTS set (TEST_RUNNER_PIQ_SNAPSHOTS=1 for xcodebuild)."
        )
        let window = try makeReviewTestWindow(width: width, height: height ?? self.height, content: content)
        defer { window.isHidden = true }

        // Let thumbnails and metadata load.
        try await Task.sleep(for: .milliseconds(1200))
        await beforeCapture()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
