import SwiftData
import XCTest
@testable import Piq

/// What saving after every decision costs: an album opened through `AppModel` on an on-disk
/// store and sorted through `SessionController.decide`, which writes each decision through and
/// saves it, as the sorting screen does. A 400-photo import, albums of 8,000, 30,000 and 50,000
/// photos (a large Recents), and a 30,000-photo session resumed 29,000 photos in. Then what a
/// library change costs a session of 50,000 photos, which has to write its photo list.
///
/// Each test prints the spread (and attaches it). Timings on a loaded machine are noisy, so the
/// budgets are loose; they catch a save that grows with the album again (when every decision
/// rewrote the photo list, one cost about 6 ms at 8,000 photos, 20 ms at 30,000 and 45 at 50,000),
/// and a photo list that is slow to write again.
@MainActor
final class PersistenceSaveCostTests: XCTestCase {
    private static let budget = Duration.milliseconds(3)

    func testSavingEveryDecisionOfA400PhotoSessionIsCheap() async throws {
        let median = try await measureDecisions(photos: 400, alreadySorted: 0, decisions: 400)
        XCTAssertLessThan(median, Self.budget, "a decision should cost a fraction of a frame to save")
    }

    func testADecisionInAn8000PhotoAlbumCostsAboutAsMuchToSave() async throws {
        let median = try await measureDecisions(photos: 8_000, alreadySorted: 0, decisions: 120)
        XCTAssertLessThan(median, Self.budget, "the photo list must not be written out with every decision")
    }

    func testADecisionInA30000PhotoAlbumCostsAboutAsMuchToSave() async throws {
        let median = try await measureDecisions(photos: 30_000, alreadySorted: 0, decisions: 120)
        XCTAssertLessThan(median, Self.budget, "the photo list must not be written out with every decision")
    }

    func testADecisionInA50000PhotoAlbumCostsAboutAsMuchToSave() async throws {
        let median = try await measureDecisions(photos: 50_000, alreadySorted: 0, decisions: 120)
        XCTAssertLessThan(median, Self.budget, "the photo list must not be written out with every decision")
    }

    func testADecisionLateInALong30000PhotoSessionStillCostsLittleToSave() async throws {
        let median = try await measureDecisions(photos: 30_000, alreadySorted: 29_000, decisions: 120)
        XCTAssertLessThan(median, Self.budget, "a long undo history and trash must stay cheap to write")
    }

    // MARK: Library changes

    /// What a library change costs a Recents of 50,000 photos, half of them sorted. Every photo
    /// added anywhere changes Recents, and Piq then reconciles its session, writes the new photo
    /// list and saves it, on the main actor, whether the session is open or not. When the list was
    /// saved as an archived `[String]`, that took 0.2–0.3 s; a change elsewhere in the library
    /// (Recents unchanged) cost an open session 30–60 ms of reconciling.
    func testALibraryChangeCostsALarge50000PhotoSessionAFewFrames() async throws {
        let costs = try await measureLibraryChanges(photos: 50_000, alreadySorted: 25_000, changes: 5)
        XCTAssertLessThan(costs.unchanged, .milliseconds(20), "an album the change didn't touch costs one comparison")
        XCTAssertLessThan(costs.addedWhileOpen, .milliseconds(150), "a photo added while sorting the album")
        XCTAssertLessThan(costs.addedWhileClosed, .milliseconds(250), "a photo added to an album sorted earlier")
    }

    // MARK: Helpers

    /// Opens a Recents of `photos` photos, `alreadySorted` of them sorted in an earlier launch, and
    /// times `changes` reloads of each kind (medians): with the session open, a change that leaves
    /// the album as it was and a photo added; after a relaunch (the session closed), a photo added.
    /// Checks that each added photo is saved, and reports the spread.
    private func measureLibraryChanges(photos: Int, alreadySorted: Int, changes: Int) async throws -> (unchanged: Duration, addedWhileOpen: Duration, addedWhileClosed: Duration) {
        let url = URL.temporaryDirectory.appending(path: "PiqChangeCost-\(UUID().uuidString).store")
        defer { Self.removeStore(at: url) }
        var ids = (0..<photos).map { _ in UUID().uuidString + "/L0/001" }
        let album = AlbumSummary(id: "recents", title: "Recents", kind: .recents, photoCount: photos, coverAssetID: ids.last)
        try autoreleasepool {
            let container = try SessionStore.makeContainer(ModelConfiguration(url: url, cloudKitDatabase: .none))
            let store = SessionStore(context: container.mainContext)
            let record = store.insertSession(albumID: album.id, title: album.title, assetIDs: ids)
            var state = record.state
            for index in 0..<alreadySorted {
                state.apply(Self.action(at: index))
            }
            record.state = state
            store.save()
        }
        let library = StubPhotoLibrary()
        library.albums = [album]
        library.albumContents = [album.id: ids]
        let clock = ContinuousClock()
        func timeReloads(of app: AppModel, adding: Bool) async -> [Duration] {
            var durations: [Duration] = []
            for _ in 0..<changes {
                if adding {
                    ids.append(UUID().uuidString + "/L0/001")
                    library.albumContents[album.id] = ids
                }
                let start = clock.now
                await app.reloadAlbums()
                durations.append(clock.now - start)
            }
            return durations
        }

        var unchanged: [Duration] = []
        var addedWhileOpen: [Duration] = []
        do {
            let app = AppModel(library: library, images: SpyImageSource(), container: try SessionStore.makeContainer(ModelConfiguration(url: url, cloudKitDatabase: .none)))
            await app.start()
            await app.openAlbum(album)
            let session = try XCTUnwrap(app.activeSession)
            XCTAssertEqual(session.state.sortedCount, alreadySorted)
            unchanged = await timeReloads(of: app, adding: false)
            addedWhileOpen = await timeReloads(of: app, adding: true)
            XCTAssertEqual(session.state.total, ids.count)
            app.returnToAlbums()
        }
        let relaunched = AppModel(library: library, images: SpyImageSource(), container: try SessionStore.makeContainer(ModelConfiguration(url: url, cloudKitDatabase: .none)))
        await relaunched.start()
        let addedWhileClosed = await timeReloads(of: relaunched, adding: true)
        let saved = try XCTUnwrap(try savedSessions(in: relaunched.container).first)
        XCTAssertEqual(saved.state.assetIDs, ids, "every added photo is saved, queued last")
        XCTAssertEqual(saved.state.sortedCount, alreadySorted)

        func spread(_ durations: [Duration]) -> String {
            durations.sorted().map(Self.ms).joined(separator: ", ")
        }
        let report = """
        \(photos.formatted())-photo album, \(alreadySorted.formatted()) sorted, \(changes) library changes of each kind (\(ProcessInfo.processInfo.processorCount) cores):
          album unchanged, session open: \(spread(unchanged))
          a photo added, session open: \(spread(addedWhileOpen))
          a photo added, session closed: \(spread(addedWhileClosed))
        """
        print(report)
        let attachment = XCTAttachment(string: report)
        attachment.name = "library-change-cost-\(photos)"
        attachment.lifetime = .keepAlways
        add(attachment)
        return (Self.median(unchanged), Self.median(addedWhileOpen), Self.median(addedWhileClosed))
    }

    private static func median(_ durations: [Duration]) -> Duration {
        durations.sorted()[durations.count / 2]
    }

    /// Opens an album of `photos` photos and sorts `decisions` of them, timing each decision: a
    /// new session, or with `alreadySorted` photos sorted (every eighth one marked) a session
    /// saved by an earlier launch and resumed. Checks that every decision is on disk, reports the
    /// spread (with the opening and the first decision, which pays for anything opening left
    /// unsaved) and returns the median.
    private func measureDecisions(photos: Int, alreadySorted: Int, decisions: Int) async throws -> Duration {
        let url = URL.temporaryDirectory.appending(path: "PiqSaveCost-\(UUID().uuidString).store")
        defer { Self.removeStore(at: url) }
        // PhotoKit-style local identifiers ("<UUID>/L0/001").
        let ids = (0..<photos).map { _ in UUID().uuidString + "/L0/001" }
        let album = AlbumSummary(id: "recents", title: "Recents", kind: .recents, photoCount: photos, coverAssetID: ids.last)
        if alreadySorted > 0 {
            try autoreleasepool {
                let container = try SessionStore.makeContainer(ModelConfiguration(url: url, cloudKitDatabase: .none))
                let store = SessionStore(context: container.mainContext)
                let record = store.insertSession(albumID: album.id, title: album.title, assetIDs: ids)
                var state = record.state
                for index in 0..<alreadySorted {
                    state.apply(Self.action(at: index))
                }
                record.state = state
                store.save()
            }
        }
        let library = StubPhotoLibrary()
        library.albums = [album]
        library.albumContents = [album.id: ids]
        let container = try SessionStore.makeContainer(ModelConfiguration(url: url, cloudKitDatabase: .none))
        let app = AppModel(library: library, images: SpyImageSource(), container: container)
        await app.start()

        let clock = ContinuousClock()
        let opening = clock.now
        await app.openAlbum(album)
        let opened = clock.now - opening
        let session = try XCTUnwrap(app.activeSession)
        XCTAssertEqual(session.state.sortedCount, alreadySorted)
        var durations: [Duration] = []
        for index in alreadySorted..<(alreadySorted + decisions) {
            let action = Self.action(at: index)
            durations.append(clock.measure { session.decide(action) })
        }

        XCTAssertEqual(try savedSessions(in: app.container).first?.state, session.state, "every decision is on disk")
        let sorted = durations.sorted()
        let report = """
        \(photos.formatted())-photo album, \(alreadySorted.formatted()) sorted before, then \(decisions) decisions, one save each (\(ProcessInfo.processInfo.processorCount) cores):
          decide, write through and save: median \(Self.ms(sorted[sorted.count / 2])), p90 \(Self.ms(sorted[sorted.count * 9 / 10])), max \(Self.ms(sorted[sorted.count - 1])); first \(Self.ms(durations[0])); opening the album \(Self.ms(opened))
          decisions stored: \(session.record.decisions.count.formatted()) bytes; store file \(Self.size(of: url).formatted()) bytes
        """
        print(report)
        let attachment = XCTAttachment(string: report)
        attachment.name = "save-cost-\(photos)-\(alreadySorted)"
        attachment.lifetime = .keepAlways
        add(attachment)
        return sorted[sorted.count / 2]
    }

    private static func action(at index: Int) -> SwipeAction {
        index % 8 == 3 ? .delete : .keep
    }

    /// "1.24 ms"
    private static func ms(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.2f ms", seconds * 1000)
    }

    private static func size(of url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? Int) ?? 0
    }

    private static func removeStore(at url: URL) {
        let folder = url.deletingLastPathComponent()
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: folder.appending(path: url.lastPathComponent + suffix))
        }
    }
}
