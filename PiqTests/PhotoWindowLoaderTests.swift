import XCTest
@testable import Piq

@MainActor
final class PhotoWindowLoaderTests: XCTestCase {
    private var lisbon: String { MockPhotoLibrary.lisbonAlbumID }

    func testTheWindowIsTheCurrentPhotoAndTheNextThree() {
        let state = SortingState(assetIDs: (1...10).map { "p\($0)" })
        XCTAssertEqual(PhotoWindowLoader.lookahead, 3)
        XCTAssertEqual(state.window(lookahead: PhotoWindowLoader.lookahead), ["p1", "p2", "p3", "p4"])
    }

    func testLoadsTheWindowAndReleasesPhotosThatLeaveIt() async throws {
        let library = MockPhotoLibrary()
        let loader = PhotoWindowLoader(images: MockImageSource(library: library), library: library)
        var state = SortingState(assetIDs: library.photoIDs(inAlbum: lisbon))
        let first = state.window(lookahead: PhotoWindowLoader.lookahead)

        loader.show(first)

        XCTAssertEqual(Set(loader.slots.keys), Set(first))
        await pollUntil("the whole window loads") {
            first.allSatisfy { loader.slot(for: $0)?.isSharp == true && loader.slot(for: $0)?.metadata != nil }
        }
        let next = try XCTUnwrap(loader.slot(for: first[1]))

        state.apply(.keep)
        let second = state.window(lookahead: PhotoWindowLoader.lookahead)
        loader.show(second)

        XCTAssertEqual(Set(loader.slots.keys), Set(second))
        XCTAssertNil(loader.slot(for: first[0]), "the sorted photo is released")
        XCTAssertTrue(loader.slot(for: first[1]) === next, "photos still in the window aren't loaded again")
        XCTAssertTrue(next.isSharp)

        loader.releaseAll()
        XCTAssertTrue(loader.slots.isEmpty)
    }

    func testAPhotoShowsItsPreviewWhileTheSharpImageDownloads() async throws {
        let library = MockPhotoLibrary()
        let images = MockImageSource(library: library, fullImageLatency: .seconds(1))
        let loader = PhotoWindowLoader(images: images, library: library)
        let id = library.photoIDs(inAlbum: lisbon)[0]

        loader.show([id])

        let slot = try XCTUnwrap(loader.slot(for: id))
        await pollUntil("a blurry preview while the sharp image downloads") {
            slot.preview != nil && slot.downloadProgress != nil
        }
        XCTAssertFalse(slot.isSharp)
        XCTAssertTrue(slot.displayImage === slot.preview)
        await pollUntil("the sharp image") { slot.isSharp }
        XCTAssertNil(slot.downloadProgress)
        XCTAssertTrue(slot.displayImage === slot.image)
        XCTAssertFalse(slot.didFail)
        XCTAssertEqual(slot.metadata?.id, id)
    }

    func testAPhotoThatCannotBeLoadedIsMarkedFailed() async throws {
        let library = MockPhotoLibrary()
        let loader = PhotoWindowLoader(images: MockImageSource(library: library), library: library)

        loader.show(["deleted-photo"])

        let slot = try XCTUnwrap(loader.slot(for: "deleted-photo"))
        await pollUntil("the load gives up") { slot.didFail }
        XCTAssertNil(slot.displayImage)
        XCTAssertNil(slot.metadata)
        XCTAssertNil(slot.downloadProgress)
    }

    func testOnlyUpcomingPhotosArePrefetchedAndStalePrefetchesStop() {
        let images = SpyImageSource()
        let loader = PhotoWindowLoader(images: images, library: StubPhotoLibrary())

        loader.show(["a", "b", "c", "d"])
        XCTAssertEqual(images.startedCaching, [["c", "d"]], "the current and the next photo are requested directly")

        loader.show(["b", "c", "d", "e"])
        XCTAssertEqual(images.startedCaching, [["c", "d"], ["e"]])
        XCTAssertEqual(images.stoppedCaching, [])

        loader.show(["c", "d", "e", "f"])
        XCTAssertEqual(images.stoppedCaching, [], "b was never cached")

        loader.show(["d", "e", "f", "g"])
        XCTAssertEqual(images.stoppedCaching, [["c"]])

        loader.releaseAll()
        XCTAssertEqual(images.stoppedCaching.count, 2)
        XCTAssertEqual(Set(images.stoppedCaching.last ?? []), ["d", "e", "f", "g"])
    }
}
