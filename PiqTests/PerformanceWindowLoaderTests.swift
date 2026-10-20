import UIKit
import XCTest
@testable import Piq

/// The order and amount of work in `PhotoWindowLoader`: what's on screen first, each photo
/// decoded once (requested at once, or taken from the cache, never requested while the cache
/// prepares it), stored previews at once and decoded previews only for sharp images that are late,
/// both only where they can show, and nothing kept going for photos that have left the window.
@MainActor
final class PerformanceWindowLoaderTests: XCTestCase {
    private let window = ["a", "b", "c", "d"]

    func testTheCurrentAndNextPhotosAreRequestedAtOnceAndTheRestOnceCached() async {
        let images = ControlledImageSource()
        let loader = PhotoWindowLoader(images: images, library: StubPhotoLibrary())

        loader.show(window)
        await settle()

        XCTAssertEqual(images.cachingStarted, [["c", "d"]], "b is requested at once: caching it too would decode it twice")
        XCTAssertEqual(images.fullRequests, ["a", "b"], "on screen first; the rest is being cached")
        await pollUntil("the photos further ahead, from the cache") { images.fullRequests.count == 4 }
        XCTAssertEqual(Set(images.fullRequests), Set(window))
        XCTAssertTrue(window.allSatisfy { loader.slot(for: $0)?.isSharp == true })
    }

    func testAPhotoThatMovesUpIsRequestedAtOnce() async {
        let images = ControlledImageSource()
        let loader = PhotoWindowLoader(images: images, library: StubPhotoLibrary())

        loader.show(window)
        await settle()
        loader.show(["b", "c", "d", "e"])
        await settle()

        XCTAssertEqual(images.fullRequests, ["a", "b", "c"], "c is next now; d and e wait for the cache")
        XCTAssertEqual(images.cachingStarted, [["c", "d"], ["e"]], "each photo cached once, as it comes in")
        await pollUntil("the rest") { images.fullRequests.count == 5 }
        XCTAssertEqual(Set(images.fullRequests), ["a", "b", "c", "d", "e"], "each photo requested once")
    }

    /// While sorting, the photo that joins the window is requested at once (it has the most time
    /// before it reaches the front), not cached first.
    func testWhenThePhotosInFrontAreSharpTheNextOneIsRequestedAtOnce() async {
        let images = ControlledImageSource()
        let loader = PhotoWindowLoader(images: images, library: StubPhotoLibrary())

        loader.show(window)
        await pollUntil("the window") { window.allSatisfy { loader.slot(for: $0)?.isSharp == true } }
        loader.show(["b", "c", "d", "e"])
        await settle()

        XCTAssertEqual(images.fullRequests.last, "e", "requested at once")
        XCTAssertEqual(images.cachingStarted, [["c", "d"]], "and not cached: it would be decoded twice")
        loader.show(["c", "d", "e", "f"])
        await settle()
        XCTAssertEqual(images.fullRequests.last, "f")
        XCTAssertEqual(Set(images.fullRequests), ["a", "b", "c", "d", "e", "f"], "each photo requested once")
        XCTAssertEqual(images.cachingStopped, [], "c and d, cached, are still in the window")
        loader.releaseAll()
    }

    /// A photo whose front isn't settled (the photo in front is still loading) waits for the
    /// cache instead, so it doesn't compete with what is on screen.
    func testWhenThePhotoInFrontIsStillLoadingTheNextOneWaitsForTheCache() async {
        let images = ControlledImageSource()
        images.holdsFullImages = true
        let loader = PhotoWindowLoader(images: images, library: StubPhotoLibrary())

        loader.show(window)
        await pollUntil("the window requested") { images.fullRequests.count == 4 }
        loader.show(["b", "c", "d", "e"])
        await settle()

        XCTAssertFalse(images.fullRequests.contains("e"), "b, in front, is still loading: e waits")
        XCTAssertEqual(images.cachingStarted, [["c", "d"], ["e"]], "for the cache")
        await pollUntil("then it is requested") { images.fullRequests.contains("e") }
        loader.releaseAll()
    }

    /// A source that keeps previews (a device's photo library) is asked for them at once, for
    /// the photos near the front, and no preview is decoded for them.
    func testAStoredPreviewIsAskedForAtOnce() async {
        let images = StoredPreviewImageSource()
        images.holdsFullImages = true
        let loader = PhotoWindowLoader(images: images, library: StubPhotoLibrary())
        let start = ContinuousClock.now

        loader.show(window)
        await pollUntil("the stored previews") { ["a", "b", "c"].allSatisfy { loader.slot(for: $0)?.preview != nil } }
        XCTAssertLessThan(ContinuousClock.now - start, PhotoWindowLoader.previewLead, "without waiting for the sharp images")
        XCTAssertEqual(Set(images.storedPreviewRequests), ["a", "b", "c"], "not the photo three ahead")
        try? await Task.sleep(for: PhotoWindowLoader.cacheLead + PhotoWindowLoader.previewLead + .milliseconds(100))
        XCTAssertEqual(images.previewRequests, [], "nothing decoded")
        loader.releaseAll()
    }

    /// A source that has no stored preview for a photo (the simulator's library) falls back to
    /// the decoded preview once the sharp image is late.
    func testWithoutAStoredPreviewTheDecodedOneComesWhenTheSharpImageIsLate() async {
        let images = StoredPreviewImageSource()
        images.holdsFullImages = true
        images.hasStoredPreviews = false
        let loader = PhotoWindowLoader(images: images, library: StubPhotoLibrary())
        let start = ContinuousClock.now

        loader.show(["a"])
        await pollUntil("the decoded preview") { loader.slot(for: "a")?.preview != nil }
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - start, PhotoWindowLoader.previewLead)
        XCTAssertEqual(images.storedPreviewRequests, ["a"])
        XCTAssertEqual(images.previewRequests, ["a"])
        loader.releaseAll()
    }

    func testAPhotoThatIsSharpSoonGetsNoPreview() async {
        let images = ControlledImageSource()
        let loader = PhotoWindowLoader(images: images, library: StubPhotoLibrary())

        loader.show(window)
        try? await Task.sleep(for: PhotoWindowLoader.cacheLead + PhotoWindowLoader.previewLead + .milliseconds(100))

        XCTAssertTrue(window.allSatisfy { loader.slot(for: $0)?.isSharp == true })
        XCTAssertEqual(images.previewRequests, [], "a preview's decode would only have slowed the sharp images down")
    }

    func testOnlyPhotosNearTheFrontWhoseSharpImageIsLateGetAPreview() async {
        let images = ControlledImageSource()
        images.holdsFullImages = true
        let loader = PhotoWindowLoader(images: images, library: StubPhotoLibrary())
        let start = ContinuousClock.now

        loader.show(window)
        await pollUntil("previews for the current and the next photo") { Set(images.previewRequests) == ["a", "b"] }
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - start, PhotoWindowLoader.previewLead, "once their sharp images are late")
        await pollUntil("c's, once its own sharp image is late") { images.previewRequests.contains("c") }
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - start, PhotoWindowLoader.cacheLead + PhotoWindowLoader.previewLead)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(Set(images.previewRequests), ["a", "b", "c"], "not the photo three ahead")

        loader.show(["b", "c", "d", "e"])
        await pollUntil("d's at once: two ahead now, and its sharp image is late already") { images.previewRequests.contains("d") }
        XCTAssertFalse(images.previewRequests.contains("e"))
        loader.releaseAll()
    }

    func testAPhotoWhoseSharpImageFailsGetsItsPreviewAtOnce() async {
        let images = ControlledImageSource()
        images.failsFullImages = true
        let loader = PhotoWindowLoader(images: images, library: StubPhotoLibrary())
        let start = ContinuousClock.now

        loader.show(["a"])
        let slot = loader.slot(for: "a")
        await pollUntil("the failure") { slot?.didFail == true }

        XCTAssertLessThan(ContinuousClock.now - start, PhotoWindowLoader.previewLead, "without waiting")
        XCTAssertNotNil(slot?.preview, "the preview is on the card when the failure shows")
        XCTAssertEqual(images.previewRequests, ["a"])
    }

    func testTheSharpImageStopsAPreviewStillOnItsWay() async {
        let images = ControlledImageSource()
        images.holdsFullImages = true
        images.holdsPreviews = true
        let loader = PhotoWindowLoader(images: images, library: StubPhotoLibrary())

        loader.show(["a"])
        await pollUntil("the preview, once the sharp image is late") { images.previewRequests == ["a"] }
        XCTAssertEqual(images.fullRequests, ["a"])

        images.answerHeldFullImages()
        await pollUntil("sharp") { loader.slot(for: "a")?.isSharp == true }
        await pollUntil("the preview request cancelled") { images.cancelled.contains("preview a") }
        XCTAssertNil(loader.slot(for: "a")?.preview)
    }

    func testRequestsForPhotosThatLeaveAreCancelled() async {
        let images = ControlledImageSource()
        images.holdsFullImages = true
        let loader = PhotoWindowLoader(images: images, library: StubPhotoLibrary())

        loader.show(window)
        await settle()
        loader.show(["e", "f", "g", "h"])
        await pollUntil("a and b cancelled") { images.cancelled.isSuperset(of: ["full a", "full b"]) }

        try? await Task.sleep(for: PhotoWindowLoader.cacheLead + .milliseconds(150))
        XCTAssertFalse(images.fullRequests.contains("c"), "c left before it was requested")
        XCTAssertFalse(images.fullRequests.contains("d"))
        XCTAssertEqual(Set(images.cachingStopped.flatMap { $0 }), ["c", "d"], "every photo that was cached, and only those")
        XCTAssertEqual(Set(loader.slots.keys), ["e", "f", "g", "h"])
        loader.releaseAll()
    }

    /// Lets the loader's tasks run up to their requests.
    private func settle() async {
        for _ in 0..<5 {
            await Task.yield()
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

/// Answers previews and full images with a 1-pixel image, at once or when the test says so (or
/// fails the full images), and records every request, cancellation and caching hint.
@MainActor
private class ControlledImageSource: PhotoImageSource {
    var holdsFullImages = false
    var holdsPreviews = false
    var failsFullImages = false
    private(set) var fullRequests: [String] = []
    private(set) var previewRequests: [String] = []
    private(set) var cancelled: Set<String> = []
    private(set) var cachingStarted: [[String]] = []
    private(set) var cachingStopped: [[String]] = []
    private var held: [String: CheckedContinuation<UIImage?, Never>] = [:]
    fileprivate static let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }

    func thumbnail(for assetID: String, pointSize: CGSize, scale: CGFloat) async -> UIImage? { Self.image }

    func preview(for assetID: String) async -> UIImage? {
        previewRequests.append(assetID)
        return holdsPreviews ? await hold("preview \(assetID)") : Self.image
    }

    func fullImage(for assetID: String, progress: @escaping @MainActor @Sendable (Double) -> Void) async -> UIImage? {
        fullRequests.append(assetID)
        if failsFullImages {
            return nil
        }
        return holdsFullImages ? await hold("full \(assetID)") : Self.image
    }

    func startCachingFullImages(for assetIDs: [String]) {
        cachingStarted.append(assetIDs)
    }

    func stopCachingFullImages(for assetIDs: [String]) {
        cachingStopped.append(assetIDs)
    }

    /// Answers the full images waiting now; later ones still wait while `holdsFullImages` is set.
    func answerHeldFullImages() {
        for (key, continuation) in held where key.hasPrefix("full ") {
            held[key] = nil
            continuation.resume(returning: Self.image)
        }
    }

    /// Waits until the test answers or the request is cancelled (then answers nil).
    private func hold(_ key: String) async -> UIImage? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                held[key] = continuation
                if Task.isCancelled {
                    cancel(key)
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(key) }
        }
    }

    private func cancel(_ key: String) {
        cancelled.insert(key)
        held.removeValue(forKey: key)?.resume(returning: nil)
    }
}

/// A `ControlledImageSource` that also keeps previews, like a device's photo library (or has none
/// for any photo, like the simulator's), and records the stored previews asked for.
@MainActor
private final class StoredPreviewImageSource: ControlledImageSource, StoredPreviewSource {
    var hasStoredPreviews = true
    private(set) var storedPreviewRequests: [String] = []

    func storedPreview(for assetID: String) async -> UIImage? {
        storedPreviewRequests.append(assetID)
        return hasStoredPreviews ? Self.image : nil
    }
}
