import Observation
import SwiftUI
import XCTest
@testable import Piq

/// `AssetThumbnail` loads at the size it's shown, loads again when it grows well past that size
/// (a window made larger), and otherwise doesn't ask twice while it is on screen. Off screen it
/// lets go of its image (a lazy grid keeps every tile's state, so a long grid would otherwise hold
/// every thumbnail it has shown), and asks again when it comes back, also after a failure.
@MainActor
final class PerformanceThumbnailTests: XCTestCase {
    func testAThumbnailLoadsAgainOnlyWhenItGrowsWellPastItsImage() async throws {
        let base = PreviewSupport.appModel(.albums)
        let photos = (base.library as? MockPhotoLibrary)?.photoIDs(inAlbum: MockPhotoLibrary.lisbonAlbumID) ?? []
        let first = try XCTUnwrap(photos.first)
        let images = ThumbnailRecorder(base: base.images)
        let app = AppModel(library: base.library, images: images, container: PreviewSupport.inMemoryContainer())
        // A grid's first layout pass, before it knows its width, gives tiles a 1-point side.
        let tile = TileModel(assetID: first, side: 1)
        let window = try makeWindow { ThumbnailHarness(tile: tile).environment(app) }
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(images.sides, [], "nothing to load for a tile too small to see")

        tile.side = 120
        await pollUntil("the first load") { images.sides.count == 1 }
        XCTAssertEqual(images.sides, [120])

        tile.side = 130
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(images.sides, [120], "a little larger: the image is still sharp enough")

        tile.side = 100
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(images.sides, [120], "smaller: nothing to load")

        tile.side = 240
        await pollUntil("loaded again at the larger size") { images.sides.count == 2 }
        XCTAssertEqual(images.sides, [120, 240])

        tile.assetID = photos[1]
        await pollUntil("another photo") { images.sides.count == 3 }
        XCTAssertEqual(images.requestedIDs.last, photos[1])
        withExtendedLifetime(base) {}
    }

    /// A tile scrolled out of a lazy grid lets go of its image, and loads it again (once) when
    /// it is scrolled back. The tile followed is one from the middle of the grid: in a portrait
    /// scene SwiftUI keeps the grid's first screen of tiles alive, so the first tile can't show it.
    func testATileScrolledAwayLetsGoOfItsImageAndLoadsItAgainWhenBack() async throws {
        let base = PreviewSupport.appModel(.albums)
        let photos = Array(((base.library as? MockPhotoLibrary)?.photoIDs(inAlbum: MockPhotoLibrary.icelandAlbumID) ?? []).prefix(240))
        let first = try XCTUnwrap(photos.first)
        let tracked = photos[120]
        let last = try XCTUnwrap(photos.last)
        let images = ThumbnailRecorder(base: base.images)
        let app = AppModel(library: base.library, images: images, container: PreviewSupport.inMemoryContainer())
        let scroll = ScrollModel()
        let window = try makeWindow { GridHarness(photos: photos, scroll: scroll).environment(app) }
        defer { window.isHidden = true }

        await pollUntil("the first row") { images.isHoldingImage(of: first) }
        let onScreen = images.liveImageCount
        // Through the grid two rows at a time, as a person scrolls.
        for row in stride(from: 2, to: photos.count / 6, by: 2) {
            scroll.target = photos[row * 6]
            try await Task.sleep(for: .milliseconds(150))
        }
        scroll.target = last
        await pollUntil("the last row") { images.requestedIDs.contains(last) }
        XCTAssertEqual(images.requestedIDs.filter { $0 == tracked }.count, 1)
        await pollUntil("the tracked tile's image let go") { !images.isHoldingImage(of: tracked) }
        // One screen of tiles in landscape; the kept first screen doubles it in portrait.
        XCTAssertLessThanOrEqual(images.liveImageCount, 2 * onScreen + 12,
                                 "only the tiles on screen (and the grid's margin) hold images, not all \(images.requestedIDs.count) shown")
        scroll.target = tracked
        await pollUntil("loaded again") { images.isHoldingImage(of: tracked) }
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(images.requestedIDs.filter { $0 == tracked }.count, 2, "once per appearance")
        withExtendedLifetime(base) {}
    }

    /// A thumbnail that couldn't be loaded (an iCloud one while offline) is asked for again when
    /// its tile next appears.
    func testAThumbnailThatFailedIsAskedForAgainWhenItsTileComesBack() async throws {
        let base = PreviewSupport.appModel(.albums)
        let photos = Array(((base.library as? MockPhotoLibrary)?.photoIDs(inAlbum: MockPhotoLibrary.icelandAlbumID) ?? []).prefix(120))
        let first = try XCTUnwrap(photos.first)
        let last = try XCTUnwrap(photos.last)
        let images = ThumbnailRecorder(base: base.images)
        images.failsOnce = [first]
        let app = AppModel(library: base.library, images: images, container: PreviewSupport.inMemoryContainer())
        let scroll = ScrollModel()
        let window = try makeWindow { GridHarness(photos: photos, scroll: scroll).environment(app) }
        defer { window.isHidden = true }

        await pollUntil("the first row") { images.requestedIDs.contains(first) }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(images.requestedIDs.filter { $0 == first }.count, 1, "no retry loop while it is on screen")
        scroll.target = last
        await pollUntil("the last row") { images.requestedIDs.contains(last) }
        scroll.target = first
        await pollUntil("asked again, and loaded") { images.isHoldingImage(of: first) }
        XCTAssertEqual(images.requestedIDs.filter { $0 == first }.count, 2)
        withExtendedLifetime(base) {}
    }

    private func makeWindow(@ViewBuilder content: () -> some View) throws -> UIWindow {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw XCTSkip("No window scene to render into")
        }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 600, height: 600)
        window.rootViewController = UIHostingController(rootView: content())
        window.isHidden = false
        return window
    }
}

@MainActor
@Observable
private final class TileModel {
    var assetID: String
    var side: CGFloat

    init(assetID: String, side: CGFloat) {
        self.assetID = assetID
        self.side = side
    }
}

private struct ThumbnailHarness: View {
    let tile: TileModel

    var body: some View {
        AssetThumbnail(assetID: tile.assetID, pointSize: CGSize(width: tile.side, height: tile.side))
            .frame(width: tile.side, height: tile.side)
    }
}

@MainActor
@Observable
private final class ScrollModel {
    var target: String?
}

/// Six columns of 80-point tiles in a 600 × 600 window: 120 photos are three screens.
private struct GridHarness: View {
    let photos: [String]
    let scroll: ScrollModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(80), spacing: 8), count: 6), spacing: 8) {
                    ForEach(photos, id: \.self) { id in
                        AssetThumbnail(assetID: id, pointSize: CGSize(width: 80, height: 80))
                            .frame(width: 80, height: 80)
                            .id(id)
                    }
                }
            }
            // The window can be given the scene's size (a portrait simulator makes it taller), so
            // the grid's viewport is fixed here to keep the number of tiles on screen the same.
            .frame(width: 600, height: 600)
            .onChange(of: scroll.target) { _, target in
                if let target {
                    proxy.scrollTo(target)
                }
            }
        }
    }
}

/// Forwards thumbnails to another image source and records the sizes asked for (points), and
/// which of the images it delivered something still holds. Fails the first request for
/// the photos in `failsOnce`.
@MainActor
private final class ThumbnailRecorder: PhotoImageSource {
    var failsOnce: Set<String> = []
    private(set) var sides: [CGFloat] = []
    private(set) var requestedIDs: [String] = []
    private var delivered: [String: WeakImage] = [:]
    private var everyDelivered: [WeakImage] = []
    private let base: any PhotoImageSource

    private struct WeakImage {
        weak var image: UIImage?
    }

    init(base: any PhotoImageSource) {
        self.base = base
    }

    /// How many of the thumbnails delivered are still alive (held by tiles).
    var liveImageCount: Int { everyDelivered.filter { $0.image != nil }.count }

    /// Whether the last thumbnail delivered for the photo is still alive (on screen).
    func isHoldingImage(of assetID: String) -> Bool {
        delivered[assetID]?.image != nil
    }

    func thumbnail(for assetID: String, pointSize: CGSize, scale: CGFloat) async -> UIImage? {
        sides.append(pointSize.width)
        requestedIDs.append(assetID)
        if failsOnce.remove(assetID) != nil {
            return nil
        }
        // A copy of its own, so that only the tile holds it.
        guard let image = await base.thumbnail(for: assetID, pointSize: pointSize, scale: scale)?.cgImage.map({ UIImage(cgImage: $0) }) else {
            return nil
        }
        delivered[assetID] = WeakImage(image: image)
        everyDelivered.append(WeakImage(image: image))
        return image
    }

    func preview(for assetID: String) async -> UIImage? { nil }

    func fullImage(for assetID: String, progress: @escaping @MainActor @Sendable (Double) -> Void) async -> UIImage? { nil }

    func startCachingFullImages(for assetIDs: [String]) {}

    func stopCachingFullImages(for assetIDs: [String]) {}
}
