import SwiftUI
import XCTest
@testable import Piq

/// Layout rules of the review screen that a screenshot can't pin down across every width.
@MainActor
final class ReviewLayoutTests: XCTestCase {
    /// Selecting changes the labels ("Restore 1", "Deselect all"), never the header's layout:
    /// otherwise the grid jumps under the finger that just tapped it.
    func testSectionHeaderLayoutIgnoresTheSelection() {
        for trashCount in [9, 50, 400] {
            for width in stride(from: 340, through: 800, by: 4) {
                let heights = Set([(0, false), (1, false), (trashCount, true)].map { selected, everything in
                    height(
                        of: TrashSectionHeader(
                            trashCount: trashCount,
                            selectedCount: selected,
                            isEverythingSelected: everything,
                            isEmptyingTrash: false,
                            toggleSelectAll: {},
                            restore: {},
                            emptyTrash: {}
                        ),
                        width: CGFloat(width)
                    )
                })
                XCTAssertEqual(heights.count, 1, "\(trashCount) in the trash, \(width)pt wide: \(heights.sorted())")
            }
        }
    }

    func testColumnCounts() {
        XCTAssertEqual(columns(inWindow: 1194), 6, "landscape")
        XCTAssertEqual(columns(inWindow: 1366), 6, "13-inch landscape")
        XCTAssertEqual(columns(inWindow: 834), 4, "portrait")
        XCTAssertEqual(columns(inWindow: 1024), 4, "13-inch portrait")
        XCTAssertEqual(columns(inWindow: 590), 4, "Split View, half of landscape")
        XCTAssertEqual(columns(inWindow: 507), 4, "Split View, half of 13-inch portrait")
        XCTAssertEqual(columns(inWindow: 480), 4)
        XCTAssertEqual(columns(inWindow: 412), 3, "half of portrait")
        XCTAssertEqual(columns(inWindow: 375), 3)
    }

    /// The counts stay to the right of the title in portrait (the summary wraps instead) and move
    /// under it in narrow windows.
    func testCountsSitBesideTheTitleInPortrait() {
        let state = PreviewSupport.session(.reviewPartial).1.state
        let portrait = height(of: ReviewHeader(state: state), width: 834 - 2 * Metrics.pageMargin(forWidth: 834))
        let narrow = height(of: ReviewHeader(state: state), width: 600 - 2 * Metrics.pageMargin(forWidth: 600))
        let landscape = height(of: ReviewHeader(state: state), width: 1194 - 2 * Metrics.pageMargin(forWidth: 1194))
        XCTAssertLessThan(portrait, narrow - 40, "beside the title in portrait, under it when narrow")
        XCTAssertLessThan(landscape, narrow - 40)
    }

    /// A window made wider (Split View to full screen) gets sharper thumbnails, not upscaled ones.
    func testThumbnailsAreRequestedAgainWhenTilesGrow() async throws {
        let base = PreviewSupport.appModel(.review)
        let session = try XCTUnwrap(base.activeSession)
        let images = StubImageSource(base: base.images)
        let app = AppModel.reviewTest(sharingLibraryOf: base, images: images)
        let window = try makeReviewTestWindow(width: 375) {
            ReviewScreen(session: session).environment(app)
        }
        defer { window.isHidden = true }
        let firstTile = session.state.markedInOrder[0]

        try await Task.sleep(for: .milliseconds(800))
        let narrow = try XCTUnwrap(images.thumbnailSides[firstTile]?.max(), "the first tile asked for a thumbnail")
        window.frame.size.width = 1194
        try await Task.sleep(for: .milliseconds(800))
        let wide = try XCTUnwrap(images.thumbnailSides[firstTile]?.max())

        XCTAssertGreaterThan(wide, narrow * 1.5, "asked again at the larger size")
        XCTAssertEqual(images.thumbnailSides[firstTile]?.count, 2, "once per size")
        withExtendedLifetime(base) {}
    }

    // MARK: Helpers

    private func columns(inWindow width: CGFloat) -> Int {
        TrashGrid.columnCount(gridWidth: width - 2 * Metrics.pageMargin(forWidth: width), windowWidth: width)
    }

    private func height(of view: some View, width: CGFloat) -> CGFloat {
        UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: 10_000)).height
    }
}
