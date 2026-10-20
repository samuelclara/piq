import XCTest
@testable import Piq

/// The scenarios behind the SwiftUI previews, mock launches and screenshots.
@MainActor
final class PreviewSupportTests: XCTestCase {
    private var iceland: String { MockPhotoLibrary.icelandAlbumID }

    /// The photos the scenarios mark: the out-of-focus mock shots, about 1 in 8.
    private func outOfFocus(_ ids: some Sequence<String>, in app: AppModel) throws -> [String] {
        let library = try mockLibrary(of: app)
        let blurry: Set<String?> = ["MockPhoto14", "MockPhoto16"]
        return ids.filter { blurry.contains(library.imageName(for: $0)) }
    }

    func testWithoutAScenarioTheModelWaitsToBeStarted() {
        let app = PreviewSupport.appModel(nil)
        XCTAssertFalse(app.hasLoadedAlbums)
        XCTAssertTrue(app.albums.isEmpty)
        XCTAssertNil(app.activeSession)
        XCTAssertEqual(app.path, [])
    }

    func testAlbumsScenarioIsLoadedWithNothingStarted() {
        let app = PreviewSupport.appModel(.albums)
        XCTAssertTrue(app.hasLoadedAlbums)
        XCTAssertEqual(app.albums.map(\.title), ["Recents", "Favorites", "Iceland 2026", "Weekend in Lisbon", "Family", "Drafts"])
        XCTAssertEqual(app.path, [])
        XCTAssertNil(app.activeSession)
        XCTAssertNil(app.resumePoint(for: iceland))
    }

    func testResumeScenarioSelectsIcelandAt38Of400() {
        let app = PreviewSupport.appModel(.resume)
        XCTAssertEqual(app.selectedAlbumID, iceland)
        XCTAssertEqual(app.selectedAlbum?.title, "Iceland 2026")
        let point = app.resumePoint(for: iceland)
        XCTAssertEqual(point?.position, 38)
        XCTAssertEqual(point?.total, 400)
        XCTAssertEqual(point?.isComplete, false)
        XCTAssertEqual(app.path, [], "still on the album picker")
    }

    func testSortingScenarioIsAt38Of400() throws {
        let app = PreviewSupport.appModel(.sorting)
        let session = try XCTUnwrap(app.activeSession)
        XCTAssertEqual(app.path, [.sorting(albumID: iceland)])
        XCTAssertEqual(session.albumTitle, "Iceland 2026")
        XCTAssertEqual(session.state.position, 38)
        XCTAssertEqual(session.state.total, 400)
        XCTAssertEqual(session.state.markedInOrder, try outOfFocus(session.state.assetIDs.prefix(37), in: app))
        XCTAssertTrue(session.state.canUndo)
    }

    func testReviewScenarioHasAll400SortedWithOneInEightMarked() throws {
        let app = PreviewSupport.appModel(.review)
        let session = try XCTUnwrap(app.activeSession)
        XCTAssertEqual(app.path, [.review(albumID: iceland)])
        XCTAssertTrue(session.state.isComplete)
        XCTAssertEqual(session.state.sortedCount, 400)
        XCTAssertEqual(session.state.markedCount, 50)
        XCTAssertEqual(session.state.keptCount, 350)
        XCTAssertEqual(session.state.markedInOrder, try outOfFocus(session.state.assetIDs, in: app))
    }

    func testReviewPartialScenarioIsPartWayThrough() throws {
        let app = PreviewSupport.appModel(.reviewPartial)
        let session = try XCTUnwrap(app.activeSession)
        XCTAssertEqual(app.path, [.sorting(albumID: iceland), .review(albumID: iceland)])
        XCTAssertEqual(session.state.sortedCount, 120)
        XCTAssertEqual(session.state.total, 400)
        XCTAssertFalse(session.state.isComplete)
        XCTAssertFalse(session.state.markedInOrder.isEmpty)
        XCTAssertEqual(session.state.markedInOrder, try outOfFocus(session.state.assetIDs.prefix(120), in: app))
    }

    func testEmptyTrashScenarioHasNothingMarked() throws {
        let app = PreviewSupport.appModel(.emptyTrash)
        let session = try XCTUnwrap(app.activeSession)
        XCTAssertEqual(app.path, [.sorting(albumID: iceland), .review(albumID: iceland)])
        XCTAssertEqual(session.state.markedCount, 0)
        XCTAssertTrue(session.state.markedInOrder.isEmpty)
        XCTAssertGreaterThan(session.state.sortedCount, 0, "photos were sorted, and all of them kept")
    }

    func testEveryScenarioSessionIsSavedAndMatchesItsRecord() throws {
        for scenario in [PreviewSupport.Scenario.resume, .sorting, .review, .reviewPartial, .emptyTrash] {
            let (app, session) = PreviewSupport.session(scenario)
            XCTAssertTrue(app.activeSession === session, "\(scenario)")
            let record = try XCTUnwrap(app.store.session(albumID: session.albumID), "\(scenario)")
            assertRecord(record, matches: session.state)
            XCTAssertEqual(
                try savedSessions(in: app.container),
                [SavedSession(albumID: iceland, albumTitle: "Iceland 2026", state: session.state)],
                "\(scenario)"
            )
        }
    }

    func testDownloadLatencyReachesTheImageSource() throws {
        let app = PreviewSupport.appModel(.sorting, fullImageLatency: .milliseconds(800))
        let images = try XCTUnwrap(app.images as? MockImageSource)
        XCTAssertEqual(images.fullImageLatency, .milliseconds(800))
    }

    func testDeletionBehaviorReachesTheLibrary() async throws {
        let app = PreviewSupport.appModel(.review, deletion: .cancel)
        XCTAssertEqual(try mockLibrary(of: app).deletionBehavior, .cancel)
        let session = try XCTUnwrap(app.activeSession)

        let outcome = await session.emptyTrash()

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(session.state.markedCount, 50)
    }

    func testAScenarioWithoutPhotosAccessShowsNoAlbums() {
        let app = PreviewSupport.appModel(.sorting, access: .denied)
        XCTAssertEqual(app.access, .denied)
        XCTAssertTrue(app.hasLoadedAlbums)
        XCTAssertTrue(app.albums.isEmpty)
        XCTAssertNil(app.activeSession)
        XCTAssertEqual(app.path, [])
    }

    func testUnitTestsRunAgainstTheMockLibrary() {
        XCTAssertNotNil(MockLaunchOptions.current, "the test host must never ask for real Photos access")
        XCTAssertTrue(AppEnvironment.makeAppModel().library is MockPhotoLibrary)
    }
}
