import SwiftData
import XCTest
@testable import Piq

/// Stores saved by builds up to phase 2, which kept a session's photo list, index, trash and
/// undo history in its one record (`EarlierLayout`). Opening such a store converts every
/// session, which then opens, resumes, undoes and empties its trash as if this build had saved it.
@MainActor
final class PersistenceMigrationTests: XCTestCase {
    /// A store file of this test's own (XCTest makes a test case object per test).
    private nonisolated let storeURL = URL.temporaryDirectory.appending(path: "PiqMigration-\(UUID().uuidString).store")

    override func tearDown() {
        Self.removeStore(at: storeURL)
    }

    func testAStoreSavedByAnEarlierBuildOpensResumesUndoesAndEmptiesItsTrash() async throws {
        try Self.writeEarlierStore(at: storeURL)
        try await Self.checkEarlierSessions(inStoreAt: storeURL)
    }

    // MARK: The earlier store

    /// Iceland 2026, sorted last: photos 1 to 6 sorted, 1, 4 and 6 in the trash.
    static let icelandDecisions: [SwipeAction] = [.delete, .keep, .keep, .delete, .keep, .delete]
    /// Weekend in Lisbon: 3 sorted, the one marked for deletion restored.
    static let lisbonDecisions: [SwipeAction] = [.keep, .delete, .keep]
    /// Family: all 18 sorted, the first 3 in the trash.
    static let familyDecisions: [SwipeAction] = (0..<18).map { $0 < 3 ? .delete : .keep }

    /// Writes the three sessions above for the mock library's albums, the way earlier builds
    /// stored them: all in the session record, the undo history as JSON-encoded decisions.
    static func writeEarlierStore(at url: URL) throws {
        let library = MockPhotoLibrary()
        let start = Date.now.addingTimeInterval(-60)
        try autoreleasepool {
            let container = try ModelContainer(for: EarlierLayout.SortingSession.self, configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
            let context = ModelContext(container)
            let sessions: [(id: String, title: String, decisions: [SwipeAction], restored: Set<Int>)] = [
                ("mock-album-family", "Family", familyDecisions, []),
                (MockPhotoLibrary.lisbonAlbumID, "Weekend in Lisbon", lisbonDecisions, [1]),
                (MockPhotoLibrary.icelandAlbumID, "Iceland 2026", icelandDecisions, []),
            ]
            for (order, session) in sessions.enumerated() {
                let ids = library.photoIDs(inAlbum: session.id)
                let history = zip(ids, session.decisions).map { SortDecision(assetID: $0, action: $1) }
                let marked = history.enumerated()
                    .filter { $0.element.action == .delete && !session.restored.contains($0.offset) }
                    .map(\.element.assetID)
                context.insert(EarlierLayout.SortingSession(
                    albumID: session.id,
                    albumTitle: session.title,
                    assetIDs: ids,
                    currentIndex: history.count,
                    markedIDs: marked,
                    historyData: try JSONEncoder().encode(history),
                    createdAt: start,
                    updatedAt: start.addingTimeInterval(Double(order + 1))
                ))
            }
            try context.save()
        }
    }

    /// Opens the store at `url` (written by an earlier build) the way Piq launches, then resumes,
    /// undoes, sorts on, empties a trash and relaunches.
    static func checkEarlierSessions(inStoreAt url: URL) async throws {
        let library = MockPhotoLibrary()
        let icelandIDs = library.photoIDs(inAlbum: MockPhotoLibrary.icelandAlbumID)
        var app = try await launch(library, storeURL: url)

        // The picker: the album sorted last is selected, and every session can be resumed.
        XCTAssertEqual(app.selectedAlbumID, MockPhotoLibrary.icelandAlbumID)
        XCTAssertEqual(app.resumePoint(for: MockPhotoLibrary.icelandAlbumID), ResumePoint(position: 7, total: 400, markedCount: 3, isComplete: false))
        XCTAssertEqual(app.resumePoint(for: MockPhotoLibrary.lisbonAlbumID), ResumePoint(position: 4, total: 36, markedCount: 0, isComplete: false))
        XCTAssertEqual(app.resumePoint(for: "mock-album-family"), ResumePoint(position: 18, total: 18, markedCount: 3, isComplete: true))
        for record in app.store.allSessions() {
            XCTAssertFalse(record.isInEarlierLayout, "\(record.albumTitle) is converted")
            XCTAssertNil(record.legacyHistoryData)
            assertRecord(record, matches: record.state)
        }

        // Resuming Iceland 2026: the same photo, trash and undo history.
        await app.openAlbum(try album("Iceland 2026", in: app))
        XCTAssertEqual(app.path, [.sorting(albumID: MockPhotoLibrary.icelandAlbumID)])
        let iceland = try XCTUnwrap(app.activeSession)
        XCTAssertEqual(iceland.state.history.map(\.action), icelandDecisions)
        XCTAssertEqual(iceland.state.markedInOrder, [icelandIDs[0], icelandIDs[3], icelandIDs[5]])
        XCTAssertEqual(iceland.state.currentAssetID, icelandIDs[6])
        XCTAssertEqual(iceland.undo(), SortDecision(assetID: icelandIDs[5], action: .delete), "Undo reverses the earlier build's last decision")
        XCTAssertEqual(iceland.state.position, 6)
        XCTAssertEqual(iceland.state.markedCount, 2)
        iceland.decide(.keep)
        let icelandNow = iceland.state
        app.returnToAlbums()

        // Family was finished: it opens on its trash, which empties.
        await app.openAlbum(try album("Family", in: app))
        XCTAssertEqual(app.path, [.review(albumID: "mock-album-family")])
        let family = try XCTUnwrap(app.activeSession)
        let outcome = await family.emptyTrash()
        XCTAssertEqual(outcome, .deleted(count: 3, undeletable: 0))
        XCTAssertEqual(family.state.total, 15)
        XCTAssertTrue(family.state.isComplete)
        XCTAssertTrue(family.state.markedIDs.isEmpty)
        app.returnToAlbums()

        // Relaunch: all of it was saved, in the current layout.
        app = try await launch(library, storeURL: url)
        XCTAssertEqual(app.selectedAlbumID, MockPhotoLibrary.icelandAlbumID)
        XCTAssertEqual(app.resumePoint(for: MockPhotoLibrary.icelandAlbumID), ResumePoint(position: 7, total: 400, markedCount: 2, isComplete: false))
        XCTAssertNil(app.resumePoint(for: "mock-album-family"), "sorted and its trash emptied")
        XCTAssertEqual(app.resumePoint(for: MockPhotoLibrary.lisbonAlbumID), ResumePoint(position: 4, total: 36, markedCount: 0, isComplete: false))
        XCTAssertEqual(try savedSessions(in: app.container).first { $0.albumID == MockPhotoLibrary.icelandAlbumID }?.state, icelandNow)
        for record in app.store.allSessions() {
            XCTAssertFalse(record.isInEarlierLayout)
            assertRecord(record, matches: record.state)
        }
    }

    // MARK: Helpers

    /// An app model over `library` and the store at `url`, started like a launch.
    private static func launch(_ library: MockPhotoLibrary, storeURL url: URL) async throws -> AppModel {
        let container = try SessionStore.makeContainer(ModelConfiguration(url: url, cloudKitDatabase: .none))
        let app = AppModel(library: library, images: SpyImageSource(), container: container)
        await app.start()
        return app
    }

    nonisolated static func removeStore(at url: URL) {
        let folder = url.deletingLastPathComponent()
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: folder.appending(path: url.lastPathComponent + suffix))
        }
    }
}

/// The session record as builds up to phase 2 defined it, field for field, so a store written
/// with it is laid out exactly as theirs were (the same entity, attributes and version hash).
enum EarlierLayout {
    @Model
    final class SortingSession {
        @Attribute(.unique) var albumID: String
        var albumTitle: String
        var assetIDs: [String]
        var currentIndex: Int
        var markedIDs: [String]
        var historyData: Data
        var createdAt: Date
        var updatedAt: Date

        init(albumID: String, albumTitle: String, assetIDs: [String], currentIndex: Int, markedIDs: [String], historyData: Data, createdAt: Date, updatedAt: Date) {
            self.albumID = albumID
            self.albumTitle = albumTitle
            self.assetIDs = assetIDs
            self.currentIndex = currentIndex
            self.markedIDs = markedIDs
            self.historyData = historyData
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }
}
