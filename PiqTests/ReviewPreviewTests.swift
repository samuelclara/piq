import XCTest
@testable import Piq

/// Loading the full-screen preview, when the sharp image fails and when it is tried again.
@MainActor
final class ReviewPreviewTests: XCTestCase {
    func testTryingAgainLoadsTheSharpPhotoAndKeepsTheQuickOneMeanwhile() async throws {
        let app = PreviewSupport.appModel(.review)
        let assetID = try XCTUnwrap(app.activeSession?.state.markedInOrder[1])
        let images = StubImageSource(base: app.images)
        images.failsFullImage = true
        let loader = ReviewPreviewLoader(assetID: assetID, images: images, library: app.library)

        loader.start()
        try await waitUntil { loader.didFail }
        let quick = try XCTUnwrap(loader.quickPreview, "the quick preview stays when the sharp image fails")

        images.failsFullImage = false
        loader.retry()
        XCTAssertFalse(loader.didFail, "loading again")
        XCTAssertTrue(loader.quickPreview === quick, "the quick preview stays on screen meanwhile")
        try await waitUntil { loader.slot?.isSharp == true }
        XCTAssertFalse(loader.didFail)
    }

    func testStartingAgainDoesNotReloadAPhotoThatIsLoaded() async throws {
        let app = PreviewSupport.appModel(.review)
        let assetID = try XCTUnwrap(app.activeSession?.state.markedInOrder[1])
        let loader = ReviewPreviewLoader(assetID: assetID, images: app.images, library: app.library)
        loader.start()
        try await waitUntil { loader.slot?.isSharp == true }
        let slot = loader.slot
        loader.start()
        XCTAssertTrue(loader.slot === slot)

        loader.release()
        XCTAssertNil(loader.slot)
        loader.start()
        try await waitUntil { loader.slot?.isSharp == true }
    }

    private func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("timed out", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
