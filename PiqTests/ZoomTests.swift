import XCTest
@testable import Piq

/// The arithmetic of pinch-to-zoom (`PhotoZoom`) and the size of the sharper image a zoomed photo
/// is shown from.
final class ZoomTests: XCTestCase {
    private let card = CGSize(width: 800, height: 600)

    func testAPinchKeepsThePointBetweenTheFingersStill() {
        var zoom = PhotoZoom()
        let anchor = CGPoint(x: 200, y: -100)
        zoom.pinchChanged(magnification: 1.5, anchor: anchor)
        zoom.pinchChanged(magnification: 2, anchor: anchor)
        XCTAssertEqual(zoom.scale, 2)
        XCTAssertTrue(zoom.isPinching)
        // The photo's point under the fingers (200, -100) shows at p * scale + offset.
        XCTAssertEqual(anchor.x * zoom.scale + zoom.offset.width, anchor.x, accuracy: 0.001)
        XCTAssertEqual(anchor.y * zoom.scale + zoom.offset.height, anchor.y, accuracy: 0.001)

        zoom.pinchEnded(content: card, viewport: card)
        XCTAssertFalse(zoom.isPinching)
        XCTAssertTrue(zoom.isZoomed)
        XCTAssertEqual(zoom.scale, 2)
        XCTAssertEqual(zoom.offset, CGSize(width: -200, height: 100), "within the edges: no change")
    }

    func testASecondPinchStartsFromTheFirst() {
        var zoom = PhotoZoom()
        zoom.pinchChanged(magnification: 2, anchor: .zero)
        zoom.pinchEnded(content: card, viewport: card)
        zoom.pinchChanged(magnification: 1.5, anchor: .zero)
        zoom.pinchEnded(content: card, viewport: card)
        XCTAssertEqual(zoom.scale, 3)
    }

    func testPinchingPastTheLimitsResistsThenSettles() {
        var zoom = PhotoZoom()
        zoom.pinchChanged(magnification: 8, anchor: .zero)
        XCTAssertEqual(zoom.scale, PhotoZoom.maxScale + 1, accuracy: 0.001, "a third of the excess past 5×")
        zoom.pinchEnded(content: card, viewport: card)
        XCTAssertEqual(zoom.scale, PhotoZoom.maxScale)

        zoom.reset()
        zoom.pinchChanged(magnification: 0.4, anchor: CGPoint(x: 100, y: 0))
        XCTAssertEqual(zoom.scale, 0.8, accuracy: 0.001, "smaller than the card, with resistance")
        zoom.pinchEnded(content: card, viewport: card)
        XCTAssertEqual(zoom, PhotoZoom(), "back to the whole photo")
        XCTAssertFalse(zoom.isZoomed)
    }

    func testAPinchThatEndsPastAnEdgeSettlesInside() {
        var zoom = PhotoZoom()
        // In on the bottom-right corner, then out around the middle: the photo would leave a gap
        // at the top and left, so it settles against those edges.
        zoom.toggle(at: CGPoint(x: 400, y: 300), content: card, viewport: card)
        XCTAssertEqual(zoom.offset, CGSize(width: -600, height: -450))
        zoom.pinchChanged(magnification: 0.6, anchor: .zero)
        XCTAssertEqual(zoom.scale, 1.5, accuracy: 0.001)
        XCTAssertEqual(zoom.offset.width, -360, accuracy: 0.001)
        zoom.pinchEnded(content: card, viewport: card)
        let limits = PhotoZoom.limits(scale: 1.5, content: card, viewport: card)
        XCTAssertEqual(limits, CGSize(width: 200, height: 150))
        XCTAssertEqual(zoom.offset.width, -200, accuracy: 0.001)
        XCTAssertEqual(zoom.offset.height, -150, accuracy: 0.001)
    }

    func testPanningMovesTheZoomedPhotoUpToItsEdges() {
        var zoom = PhotoZoom()
        // Nothing to move at 1×.
        zoom.panChanged(translation: CGSize(width: 50, height: 0), content: card, viewport: card)
        XCTAssertEqual(zoom.offset, .zero)

        zoom.toggle(at: .zero, content: card, viewport: card)
        XCTAssertEqual(zoom.scale, PhotoZoom.doubleTapScale)
        // At 2.5× the 800 × 600 photo is 2000 × 1500: 600 and 450 points each way.
        zoom.panChanged(translation: CGSize(width: 10, height: 10), content: card, viewport: card)
        zoom.panChanged(translation: CGSize(width: 110, height: -90), content: card, viewport: card)
        XCTAssertEqual(zoom.offset, CGSize(width: 100, height: -100), "measured from where the pan started")
        zoom.panChanged(translation: CGSize(width: 910, height: -90), content: card, viewport: card)
        XCTAssertEqual(zoom.offset.width, 600 + 300 / 3, accuracy: 0.001, "past the edge, with resistance")
        zoom.panEnded(translation: CGSize(width: 910, height: -90), predictedTranslation: CGSize(width: 910, height: -90), content: card, viewport: card)
        XCTAssertEqual(zoom.offset, CGSize(width: 600, height: -100), "settles at the edge")
    }

    func testAFlickGlides() {
        var zoom = PhotoZoom()
        zoom.toggle(at: .zero, content: card, viewport: card)
        zoom.panChanged(translation: .zero, content: card, viewport: card)
        zoom.panChanged(translation: CGSize(width: 40, height: 0), content: card, viewport: card)
        zoom.panEnded(translation: CGSize(width: 40, height: 0), predictedTranslation: CGSize(width: 240, height: 0), content: card, viewport: card)
        XCTAssertEqual(zoom.offset, CGSize(width: 140, height: 0), "half the predicted rest of the flick")
    }

    func testDoubleTapZoomsInAroundTheTapAndBackOut() {
        var zoom = PhotoZoom()
        let tap = CGPoint(x: 100, y: 50)
        zoom.toggle(at: tap, content: card, viewport: card)
        XCTAssertTrue(zoom.isZoomed)
        XCTAssertEqual(zoom.scale, 2.5)
        XCTAssertEqual(tap.x * zoom.scale + zoom.offset.width, tap.x, accuracy: 0.001, "the tapped point stays put")
        XCTAssertEqual(tap.y * zoom.scale + zoom.offset.height, tap.y, accuracy: 0.001)

        zoom.toggle(at: .zero, content: card, viewport: card)
        XCTAssertEqual(zoom, PhotoZoom())

        // Near a corner, the photo's edge stops at the card's.
        zoom.toggle(at: CGPoint(x: 400, y: 300), content: card, viewport: card)
        XCTAssertEqual(zoom.offset, CGSize(width: -600, height: -450))
    }

    /// In the full-screen preview the photo is aspect-fit: a portrait photo on a landscape
    /// screen can't move sideways until it is wider than the screen.
    func testAPhotoNarrowerThanTheScreenOnlyMovesWhereItOverflows() {
        let screen = CGSize(width: 1194, height: 834)
        let portrait = Metrics.fit(aspectRatio: 3.0 / 4.0, in: screen)
        XCTAssertEqual(portrait, CGSize(width: 626, height: 834))
        let limits = PhotoZoom.limits(scale: 1.5, content: portrait, viewport: screen)
        XCTAssertEqual(limits.width, 0, "939 points wide, still inside 1194")
        XCTAssertEqual(limits.height, 208.5, accuracy: 0.001)
        XCTAssertEqual(PhotoZoom.limits(scale: 2.5, content: portrait, viewport: screen).width, 185.5, accuracy: 0.001)
    }

    func testTheSharperImageAppearsOnceZoomedPastTheScreensImage() {
        var zoom = PhotoZoom()
        XCTAssertFalse(zoom.wantsDetail)
        zoom.pinchChanged(magnification: 1.1, anchor: .zero)
        XCTAssertFalse(zoom.wantsDetail)
        zoom.pinchChanged(magnification: 1.25, anchor: .zero)
        XCTAssertTrue(zoom.wantsDetail)
        zoom.pinchChanged(magnification: 0.9, anchor: .zero)
        XCTAssertFalse(zoom.wantsDetail, "let go when zoomed back out")
    }

    func testTheSharperImageIsTheOriginalUpTo24Megapixels() {
        XCTAssertEqual(PhotoKitImageSource.zoomImageSize(pixelWidth: 4032, pixelHeight: 3024), CGSize(width: 4032, height: 3024), "12 MP: as it is")
        let large = PhotoKitImageSource.zoomImageSize(pixelWidth: 8064, pixelHeight: 6048)
        XCTAssertLessThanOrEqual(large.width * large.height, 24_000_000)
        XCTAssertGreaterThan(large.width * large.height, 23_900_000)
        XCTAssertEqual(large.width / large.height, 4.0 / 3.0, accuracy: 0.001, "same shape")
        let panorama = PhotoKitImageSource.zoomImageSize(pixelWidth: 16_000, pixelHeight: 3_000)
        XCTAssertLessThanOrEqual(panorama.width * panorama.height, 24_000_000)
        XCTAssertEqual(panorama.width / panorama.height, 16.0 / 3.0, accuracy: 0.01)
        XCTAssertEqual(PhotoKitImageSource.zoomImageSize(pixelWidth: 0, pixelHeight: 0), CGSize(width: 1, height: 1))
    }
}
