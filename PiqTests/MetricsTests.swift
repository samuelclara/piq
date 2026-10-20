import CoreGraphics
import XCTest
@testable import Piq

final class MetricsTests: XCTestCase {
    // MARK: Grid columns

    func testAlbumGridHasFourColumnsInLandscapeThreeInPortraitAndTwoInSplitView() {
        XCTAssertEqual(Metrics.albumColumns(forWidth: 1194), 4, "landscape")
        XCTAssertEqual(Metrics.albumColumns(forWidth: 834), 3, "portrait")
        XCTAssertEqual(Metrics.albumColumns(forWidth: 600), 2, "half-screen Split View")
        XCTAssertEqual(Metrics.albumColumns(forWidth: 375), 2, "narrowest Split View")
    }

    func testAlbumGridBreakpoints() {
        XCTAssertEqual(Metrics.albumColumns(forWidth: 1000), 4)
        XCTAssertEqual(Metrics.albumColumns(forWidth: 999.5), 3)
        XCTAssertEqual(Metrics.albumColumns(forWidth: 640), 3)
        XCTAssertEqual(Metrics.albumColumns(forWidth: 639.5), 2)
    }

    func testReviewGridHasSixColumnsInLandscapeAndFourInPortraitAndSplitView() {
        XCTAssertEqual(Metrics.reviewColumns(forWidth: 1194), 6, "landscape")
        XCTAssertEqual(Metrics.reviewColumns(forWidth: 834), 4, "portrait")
        XCTAssertEqual(Metrics.reviewColumns(forWidth: 600), 4, "half-screen Split View")
        XCTAssertEqual(Metrics.reviewColumns(forWidth: 375), 3, "narrowest Split View")
    }

    func testReviewGridBreakpoints() {
        XCTAssertEqual(Metrics.reviewColumns(forWidth: 1000), 6)
        XCTAssertEqual(Metrics.reviewColumns(forWidth: 999.5), 4)
        XCTAssertEqual(Metrics.reviewColumns(forWidth: 480), 4)
        XCTAssertEqual(Metrics.reviewColumns(forWidth: 479.5), 3)
    }

    func testPageMarginShrinksInNarrowWindows() {
        XCTAssertEqual(Metrics.pageMargin(forWidth: 1194), Metrics.pageMargin)
        XCTAssertEqual(Metrics.pageMargin(forWidth: 834), 28)
        XCTAssertEqual(Metrics.pageMargin(forWidth: 500), 28)
        XCTAssertEqual(Metrics.pageMargin(forWidth: 375), 16)
    }

    // MARK: Fitting photos

    func testAWidePhotoOnTheLandscapeStageIsLimitedByHeight() {
        XCTAssertEqual(Metrics.fit(aspectRatio: 3.0 / 2.0, in: CGSize(width: 900, height: 560)), CGSize(width: 840, height: 560))
    }

    func testATallPhotoIsLimitedByHeight() {
        XCTAssertEqual(Metrics.fit(aspectRatio: 2.0 / 3.0, in: CGSize(width: 900, height: 560)), CGSize(width: 373, height: 560))
    }

    func testAWidePhotoInANarrowBoxIsLimitedByWidth() {
        XCTAssertEqual(Metrics.fit(aspectRatio: 3.0 / 2.0, in: CGSize(width: 500, height: 700)), CGSize(width: 500, height: 333))
        XCTAssertEqual(Metrics.fit(aspectRatio: 4, in: CGSize(width: 900, height: 560)), CGSize(width: 900, height: 225), "a panorama")
    }

    func testAPhotoWithTheBoxsShapeFillsIt() {
        XCTAssertEqual(Metrics.fit(aspectRatio: 3.0 / 2.0, in: CGSize(width: 900, height: 600)), CGSize(width: 900, height: 600))
    }

    func testDegenerateInputFitsNothing() {
        for ratio in [0, -1.5, CGFloat.nan] {
            XCTAssertEqual(Metrics.fit(aspectRatio: ratio, in: CGSize(width: 900, height: 560)), .zero, "aspect ratio \(ratio)")
        }
        for box in [CGSize.zero, CGSize(width: 900, height: 0), CGSize(width: 0, height: 560), CGSize(width: -900, height: 560)] {
            XCTAssertEqual(Metrics.fit(aspectRatio: 1.5, in: box), .zero, "box \(box)")
        }
    }

    func testAFittedPhotoStaysInsideTheBoxTouchesAnEdgeAndKeepsItsShape() {
        let ratios: [CGFloat] = [0.25, 0.5, 2.0 / 3.0, 0.75, 1, 4.0 / 3.0, 1.5, 16.0 / 9.0, 3, 6]
        let boxes = [CGSize(width: 900, height: 560), CGSize(width: 754, height: 900), CGSize(width: 343, height: 480), CGSize(width: 1114, height: 640)]
        for ratio in ratios {
            for box in boxes {
                let size = Metrics.fit(aspectRatio: ratio, in: box)
                let label = "ratio \(ratio) in \(box): \(size)"
                XCTAssertLessThanOrEqual(size.width, box.width, label)
                XCTAssertLessThanOrEqual(size.height, box.height, label)
                XCTAssertTrue(size.width == box.width || size.height == box.height, label)
                XCTAssertEqual(size.width, size.height * ratio, accuracy: max(1, ratio), label)
            }
        }
    }

    // MARK: Spec constants

    func testLayoutAndSwipeConstantsMatchTheSpec() {
        XCTAssertEqual(Metrics.topBarHeight, 76)
        XCTAssertEqual(Metrics.progressWidth, 260)
        XCTAssertEqual(Metrics.photoCorner, 14)
        XCTAssertEqual(Metrics.tileCorner, 14)
        XCTAssertEqual(Metrics.thumbCorner, 12)
        XCTAssertEqual(Metrics.thumbGap, 12)
        XCTAssertEqual(Metrics.albumCoverHeight, 172)
        XCTAssertEqual(Metrics.actionButtonHeight, 56)
        XCTAssertGreaterThanOrEqual(Metrics.minTouch, 44)
        XCTAssertEqual(Metrics.swipeThreshold, 140)
        XCTAssertEqual(Metrics.maxOverlayOpacity, 0.85)
        XCTAssertEqual(Metrics.tiltDivisor, 28)
        XCTAssertEqual(Metrics.flyOffDuration, 0.26)
        XCTAssertEqual(Metrics.stackScale, 0.93)
        XCTAssertEqual(Metrics.stackOffset, 18)
        XCTAssertEqual(Metrics.stackOpacity, 0.35)
        XCTAssertEqual(Metrics.toastDuration, .milliseconds(2200))
    }
}
