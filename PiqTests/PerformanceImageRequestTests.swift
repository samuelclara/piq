import Photos
import UIKit
import XCTest
@testable import Piq

/// `PendingImageRequest`, which bridges one PhotoKit image request to the task awaiting it: it
/// answers exactly once (a second answer would trap the checked continuation), never starts a
/// PhotoKit request for a task that is already cancelled, cancels the request when the task is
/// cancelled, and stops a request whose first answer is a quick degraded image, since nothing
/// waits for the better one.
@MainActor
final class PerformanceImageRequestTests: XCTestCase {
    private static let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }

    func testATaskCancelledBeforeItAsksNeverStartsARequest() async {
        let request = PendingImageRequest()
        request.cancel()
        var mayStart = true
        let delivery = await withCheckedContinuation { continuation in
            mayStart = request.begin(continuation)
        }
        XCTAssertFalse(mayStart, "no PhotoKit request")
        XCTAssertNil(delivery.image)
    }

    func testCancellingCancelsThePhotoKitRequestAndIgnoresALateAnswer() async {
        let request = PendingImageRequest()
        let cancelled = CancelLog()
        let delivery = await withCheckedContinuation { continuation in
            XCTAssertTrue(request.begin(continuation))
            request.attach(7) { cancelled.ids.append($0) }
            request.cancel()
            request.finish(ImageDelivery(image: Self.image, info: nil))
        }
        XCTAssertNil(delivery.image, "the cancel answered first")
        XCTAssertEqual(cancelled.ids, [7])
    }

    /// A cancel that comes while PhotoKit is starting the request (before its ID is known)
    /// cancels it as soon as the ID is.
    func testACancelBeforeTheRequestIDIsKnownCancelsOnceItIs() async {
        let request = PendingImageRequest()
        let cancelled = CancelLog()
        let delivery = await withCheckedContinuation { continuation in
            XCTAssertTrue(request.begin(continuation))
            request.cancel()
            request.attach(9) { cancelled.ids.append($0) }
        }
        XCTAssertNil(delivery.image)
        XCTAssertEqual(cancelled.ids, [9])
    }

    func testADegradedFirstAnswerIsDeliveredAndStopsTheRequest() async {
        let cancelled = CancelLog()
        // Opportunistic requests may answer synchronously, before their ID is known.
        let early = PendingImageRequest()
        let first = await withCheckedContinuation { continuation in
            XCTAssertTrue(early.begin(continuation))
            early.finish(ImageDelivery(image: Self.image, info: [PHImageResultIsDegradedKey: true]))
            early.attach(3) { cancelled.ids.append($0) }
            early.finish(ImageDelivery(image: Self.image, info: nil))
        }
        XCTAssertTrue(first.isDegraded)
        XCTAssertEqual(cancelled.ids, [3], "stopped once its ID is known")

        let late = PendingImageRequest()
        let second = await withCheckedContinuation { continuation in
            XCTAssertTrue(late.begin(continuation))
            late.attach(4) { cancelled.ids.append($0) }
            late.finish(ImageDelivery(image: Self.image, info: [PHImageResultIsDegradedKey: true]))
        }
        XCTAssertNotNil(second.image)
        XCTAssertEqual(cancelled.ids, [3, 4])
    }

    func testAFullQualityAnswerIsDeliveredAndNothingIsCancelled() async {
        let request = PendingImageRequest()
        let cancelled = CancelLog()
        let delivery = await withCheckedContinuation { continuation in
            XCTAssertTrue(request.begin(continuation))
            request.attach(5) { cancelled.ids.append($0) }
            request.finish(ImageDelivery(image: Self.image, info: nil))
        }
        request.cancel()
        XCTAssertNotNil(delivery.image)
        XCTAssertFalse(delivery.isDegraded)
        XCTAssertEqual(cancelled.ids, [], "nothing left to cancel once answered")
    }
}

/// The request IDs a `PendingImageRequest` asked PhotoKit to cancel.
private final class CancelLog {
    var ids: [PHImageRequestID] = []
}
