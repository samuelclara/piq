import SwiftData
import XCTest
@testable import Piq

/// Stores saved by builds before Previous and Next (up to commit fa2f801), where sorting was a
/// prefix: a session's photo list in `SessionPhotos`, one letter per sorted photo in `decisions`,
/// and no cursor or undo log (`PrefixLayout`). Such a store opens in this build unchanged: each
/// session's cursor is its number of decisions, its decisions are those letters (the first photos,
/// in order), and its undo history is the same decisions in the same order. It then resumes,
/// undoes, moves, replaces a decision and relaunches as if this build had saved it.
@MainActor
final class NavigationMigrationTests: XCTestCase {
    /// A store file of this test's own (XCTest makes a test case object per test).
    private nonisolated let storeURL = URL.temporaryDirectory.appending(path: "PiqPrefixLayout-\(UUID().uuidString).store")

    override func tearDown() {
        PersistenceMigrationTests.removeStore(at: storeURL)
    }

    /// Iceland 2026, sorted last: photos 1 to 6 sorted, 1, 4 and 6 in the trash.
    static let icelandLetters = "DkkDkD"
    /// Weekend in Lisbon: 3 sorted, the one marked for deletion restored ("d", lower case).
    static let lisbonLetters = "kdk"
    /// Family: all 18 sorted, the first 3 in the trash.
    static let familyLetters = "DDD" + String(repeating: "k", count: 15)

    func testAStoreSavedBeforePreviousAndNextOpensExactlyAsItWas() async throws {
        try Self.writePrefixStore(at: storeURL)
        let library = MockPhotoLibrary()
        let icelandIDs = library.photoIDs(inAlbum: MockPhotoLibrary.icelandAlbumID)
        let lisbonIDs = library.photoIDs(inAlbum: MockPhotoLibrary.lisbonAlbumID)
        var app = try await launch(library)

        // Every session converts exactly: cursor after its decisions, the same decisions, trash
        // and undo history; nothing is written until the person changes something.
        let iceland = try XCTUnwrap(app.store.session(albumID: MockPhotoLibrary.icelandAlbumID))
        XCTAssertNil(iceland.cursor, "read as it is, not rewritten on launch")
        XCTAssertNil(iceland.undoLog)
        let icelandState = iceland.state
        XCTAssertEqual(icelandState.currentIndex, 6)
        XCTAssertEqual(icelandState.currentAssetID, icelandIDs[6])
        XCTAssertEqual(icelandState.history, zip(icelandIDs, [SwipeAction.delete, .keep, .keep, .delete, .keep, .delete]).map { SortDecision(assetID: $0, action: $1) })
        XCTAssertEqual(icelandState.decisions, Dictionary(uniqueKeysWithValues: icelandState.history.map { ($0.assetID, $0.action) }))
        XCTAssertEqual(icelandState.markedInOrder, [icelandIDs[0], icelandIDs[3], icelandIDs[5]])
        let lisbon = try XCTUnwrap(app.store.session(albumID: MockPhotoLibrary.lisbonAlbumID)).state
        XCTAssertEqual(lisbon.currentIndex, 3)
        XCTAssertEqual(lisbon.verdict(for: lisbonIDs[1]), Verdict(action: .delete, isMarked: false), "restored: counts as kept")
        XCTAssertEqual(lisbon.keptCount, 3)
        XCTAssertEqual(app.selectedAlbumID, MockPhotoLibrary.icelandAlbumID, "the album sorted last")
        XCTAssertEqual(app.resumePoint(for: MockPhotoLibrary.icelandAlbumID), ResumePoint(position: 7, total: 400, markedCount: 3, isComplete: false))
        XCTAssertEqual(app.resumePoint(for: MockPhotoLibrary.lisbonAlbumID), ResumePoint(position: 4, total: 36, markedCount: 0, isComplete: false))
        XCTAssertEqual(app.resumePoint(for: "mock-album-family"), ResumePoint(position: 18, total: 18, markedCount: 3, isComplete: true))

        // Resuming Iceland: the same photo, Undo takes back the earlier build's last decision.
        await app.openAlbum(try album("Iceland 2026", in: app))
        XCTAssertEqual(app.path, [.sorting(albumID: MockPhotoLibrary.icelandAlbumID)])
        let session = try XCTUnwrap(app.activeSession)
        XCTAssertEqual(session.state, icelandState)
        XCTAssertEqual(session.undo(), SortDecision(assetID: icelandIDs[5], action: .delete))
        assertRecord(session.record, matches: session.state)
        // Back two photos, change a decision, skip one.
        session.step(.previous)
        session.step(.previous)
        XCTAssertEqual(session.state.currentAssetID, icelandIDs[3])
        XCTAssertEqual(session.decide(.keep)?.replaced, Verdict(action: .delete, isMarked: true))
        session.step(.next)
        session.step(.next)
        XCTAssertEqual(session.decide(.delete)?.assetID, icelandIDs[6])
        assertRecord(session.record, matches: session.state)
        let icelandNow = session.state
        XCTAssertEqual(icelandNow.markedInOrder, [icelandIDs[0], icelandIDs[6]])
        XCTAssertNil(icelandNow.verdict(for: icelandIDs[5]), "photo 6 is unsorted again")
        app.returnToAlbums()

        // Family was finished: it opens on its trash, which empties.
        await app.openAlbum(try album("Family", in: app))
        XCTAssertEqual(app.path, [.review(albumID: "mock-album-family")])
        let outcome = await app.activeSession?.emptyTrash()
        XCTAssertEqual(outcome, .deleted(count: 3, undeletable: 0))
        app.returnToAlbums()

        // Relaunch: all of it saved, in this build's layout.
        app = try await launch(library)
        XCTAssertEqual(try savedSessions(in: app.container).first { $0.albumID == MockPhotoLibrary.icelandAlbumID }?.state, icelandNow)
        XCTAssertEqual(app.resumePoint(for: MockPhotoLibrary.icelandAlbumID), ResumePoint(position: 6, total: 400, markedCount: 2, isComplete: false), "photo 6 is the first unsorted one")
        XCTAssertNil(app.resumePoint(for: "mock-album-family"))
        await app.openAlbum(try album("Iceland 2026", in: app))
        XCTAssertEqual(app.activeSession?.state.currentAssetID, icelandIDs[5], "resumes at the first unsorted photo")
        XCTAssertEqual(app.activeSession?.undo()?.assetID, icelandIDs[6], "the undo history survived")
    }

    /// A store of fa2f801 has no cursor or undo log: SwiftData's lightweight migration adds them,
    /// empty (nil), and leaves everything else as it was.
    func testTheNewFieldsOfAConvertedSessionAreEmpty() async throws {
        try Self.writePrefixStore(at: storeURL)
        let container = try SessionStore.makeContainer(ModelConfiguration(url: storeURL, cloudKitDatabase: .none))
        let records = try ModelContext(container).fetch(FetchDescriptor<SortingSession>())
        XCTAssertEqual(records.count, 3)
        for record in records {
            XCTAssertNil(record.cursor, record.albumTitle)
            XCTAssertNil(record.undoLog, record.albumTitle)
            XCTAssertFalse(record.isInEarlierLayout)
            XCTAssertEqual(record.photoCount, record.photos?.assetIDs.count)
        }
    }

    // MARK: The store of fa2f801

    /// Writes the three sessions above for the mock library's albums, the way fa2f801 stored them.
    static func writePrefixStore(at url: URL) throws {
        let library = MockPhotoLibrary()
        let start = Date.now.addingTimeInterval(-60)
        try autoreleasepool {
            let container = try ModelContainer(
                for: PrefixLayout.SortingSession.self, PrefixLayout.SessionPhotos.self,
                configurations: ModelConfiguration(url: url, cloudKitDatabase: .none)
            )
            let context = ModelContext(container)
            let sessions = [
                ("mock-album-family", "Family", familyLetters),
                (MockPhotoLibrary.lisbonAlbumID, "Weekend in Lisbon", lisbonLetters),
                (MockPhotoLibrary.icelandAlbumID, "Iceland 2026", icelandLetters),
            ]
            for (order, (id, title, letters)) in sessions.enumerated() {
                let record = PrefixLayout.SortingSession(albumID: id, albumTitle: title, createdAt: start, updatedAt: start.addingTimeInterval(Double(order + 1)))
                context.insert(record)
                let ids = library.photoIDs(inAlbum: id)
                let photos = PrefixLayout.SessionPhotos(packedIDs: SessionPhotos.pack(ids))
                context.insert(photos)
                record.photos = photos
                record.photoCount = ids.count
                record.decisions = Data(letters.utf8)
            }
            try context.save()
        }
    }

    private func launch(_ library: MockPhotoLibrary) async throws -> AppModel {
        let container = try SessionStore.makeContainer(ModelConfiguration(url: storeURL, cloudKitDatabase: .none))
        let app = AppModel(library: library, images: SpyImageSource(), container: container)
        await app.start()
        return app
    }
}

/// The session records as commit fa2f801 defined them, field for field, so a store written with
/// them is laid out exactly as that build's (the same entities, attributes and version hashes).
enum PrefixLayout {
    @Model
    final class SortingSession {
        @Attribute(.unique) var albumID: String
        var albumTitle: String
        @Relationship(deleteRule: .cascade, inverse: \PrefixLayout.SessionPhotos.session) var photos: PrefixLayout.SessionPhotos?
        var photoCount: Int = 0
        var decisions = Data()
        var createdAt: Date
        var updatedAt: Date
        @Attribute(originalName: "assetIDs") var legacyAssetIDs: [String]?
        @Attribute(originalName: "currentIndex") var legacyCurrentIndex: Int?
        @Attribute(originalName: "markedIDs") var legacyMarkedIDs: [String]?
        @Attribute(originalName: "historyData") var legacyHistoryData: Data?

        init(albumID: String, albumTitle: String, createdAt: Date, updatedAt: Date) {
            self.albumID = albumID
            self.albumTitle = albumTitle
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }

    @Model
    final class SessionPhotos {
        var packedIDs = Data()
        var session: PrefixLayout.SortingSession?

        init(packedIDs: Data) {
            self.packedIDs = packedIDs
        }
    }
}
