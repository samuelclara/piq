import SwiftData
import XCTest
@testable import Piq

// MARK: Waiting

extension XCTestCase {
    /// Checks `condition` every 10 ms until it holds, for debounced or asynchronous work, and
    /// fails the test if it still doesn't hold after `timeout`. Returns whether it held.
    @MainActor
    @discardableResult
    func pollUntil(
        _ description: @autoclosure () -> String,
        timeout: Duration = .seconds(5),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out after \(timeout) waiting until \(description())", file: file, line: line)
                return false
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

// MARK: Sessions

/// One album's session, wired the way `AppModel` wires it: a library, an in-memory SwiftData
/// store, a saved `SortingSession` record and a `SessionController` on top. Keep the fixture
/// alive while using its record.
@MainActor
struct SessionFixture<Library: PhotoLibraryClient> {
    let library: Library
    let container: ModelContainer
    let store: SessionStore
    let record: SortingSession
    let session: SessionController
    /// The album's photos, oldest first, as the session started.
    let ids: [String]

    init(library: Library, albumID: String, title: String, assetIDs: [String]) {
        let container = PreviewSupport.inMemoryContainer()
        let store = SessionStore(context: container.mainContext)
        let record = store.insertSession(albumID: albumID, title: title, assetIDs: assetIDs)
        self.library = library
        self.container = container
        self.store = store
        self.record = record
        self.session = SessionController(record: record, store: store, library: library)
        self.ids = assetIDs
    }
}

extension SessionFixture where Library == MockPhotoLibrary {
    /// "Weekend in Lisbon" (36 photos) from the mock library.
    init(deletion: MockPhotoLibrary.DeletionBehavior = .succeed) {
        let library = MockPhotoLibrary()
        library.deletionBehavior = deletion
        let albumID = MockPhotoLibrary.lisbonAlbumID
        self.init(library: library, albumID: albumID, title: "Weekend in Lisbon", assetIDs: library.photoIDs(inAlbum: albumID))
    }
}

extension SessionController {
    /// Sorts the next photos with `actions`, in order.
    @discardableResult
    func sortNext(_ actions: [SwipeAction]) -> [SortDecision] {
        actions.compactMap { decide($0) }
    }
}

/// Asserts that `record`'s stored fields describe exactly `state`: the photo list and its count,
/// and one letter per sorted photo for its decision, in upper case while it is in the trash.
@MainActor
func assertRecord(_ record: SortingSession, matches state: SortingState, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(record.photos?.assetIDs, state.assetIDs, "photos", file: file, line: line)
    XCTAssertEqual(record.photoCount, state.total, "photoCount", file: file, line: line)
    XCTAssertEqual(String(decoding: record.decisions, as: UTF8.self), decisionLetters(state), "decisions", file: file, line: line)
    XCTAssertFalse(record.isInEarlierLayout, "nothing left in the earlier layout", file: file, line: line)
}

/// What `SortingSession.decisions` holds for `state`, spelled out: "kDkd" is a keep, a photo in
/// the trash, a keep and a photo marked for deletion and then restored.
func decisionLetters(_ state: SortingState) -> String {
    state.history.map { decision in
        let letter = switch decision.action {
        case .delete: "d"
        case .keep: "k"
        }
        return state.isMarked(decision.assetID) ? letter.uppercased() : letter
    }.joined()
}

/// A session as the store has it on disk (or in memory), detached from any context.
struct SavedSession: Equatable {
    let albumID: String
    let albumTitle: String
    let state: SortingState
}

/// The sessions saved in `container`, sorted by album ID. Reads through a fresh context, so
/// changes the main context hasn't saved yet don't show.
@MainActor
func savedSessions(in container: ModelContainer) throws -> [SavedSession] {
    let context = ModelContext(container)
    return try context.fetch(FetchDescriptor<SortingSession>())
        .map { SavedSession(albumID: $0.albumID, albumTitle: $0.albumTitle, state: $0.state) }
        .sorted { $0.albumID < $1.albumID }
}

/// An in-memory store for records that don't need a controller.
@MainActor
struct RecordStore {
    let container: ModelContainer

    init() {
        container = PreviewSupport.inMemoryContainer()
    }

    func insert(albumID: String = "album", title: String = "Iceland 2026", assetIDs: [String]) -> SortingSession {
        let record = SortingSession(albumID: albumID, albumTitle: title, assetIDs: assetIDs)
        container.mainContext.insert(record)
        return record
    }
}

// MARK: App

/// An app model over a fresh mock library (full access) and in-memory store, started the way the
/// root view starts it.
@MainActor
func startedApp() async throws -> (app: AppModel, library: MockPhotoLibrary) {
    let app = PreviewSupport.appModel(nil)
    await app.start()
    return (app, try mockLibrary(of: app))
}

@MainActor
func mockLibrary(of app: AppModel, file: StaticString = #filePath, line: UInt = #line) throws -> MockPhotoLibrary {
    try XCTUnwrap(app.library as? MockPhotoLibrary, "Expected the mock library", file: file, line: line)
}

@MainActor
func album(_ title: String, in app: AppModel, file: StaticString = #filePath, line: UInt = #line) throws -> AlbumSummary {
    try XCTUnwrap(app.albums.first { $0.title == title }, "No album named \(title)", file: file, line: line)
}
