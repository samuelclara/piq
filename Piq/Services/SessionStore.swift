import OSLog
import SwiftData

/// SwiftData access for sorting sessions (main context only).
@MainActor
final class SessionStore {
    let context: ModelContext
    /// A context doesn't keep its container alive, and once the container is gone SwiftData
    /// invalidates every record fetched through it (touching one traps). Holding the container
    /// here keeps the records usable for as long as anything holds the store, such as a session
    /// controller still finishing a deletion.
    private let container: ModelContainer

    /// Opens the store of `context`, bringing any session saved by an earlier build into the
    /// current layout.
    init(context: ModelContext) {
        self.context = context
        self.container = context.container
        convertSessionsInEarlierLayout()
    }

    /// A container for sessions: the default store on disk, unless `configuration` says otherwise.
    static func makeContainer(_ configuration: ModelConfiguration? = nil) throws -> ModelContainer {
        guard let configuration else {
            return try ModelContainer(for: SortingSession.self, SessionPhotos.self)
        }
        return try ModelContainer(for: SortingSession.self, SessionPhotos.self, configurations: configuration)
    }

    // There is one session per album, so filtering and sorting in memory is cheap, and it keeps
    // key paths to the model out of Sendable predicates and sort descriptors.

    func session(albumID: String) -> SortingSession? {
        allSessions().first { $0.albumID == albumID }
    }

    /// Every saved session, the one the person worked on last first.
    func allSessions() -> [SortingSession] {
        let sessions = (try? context.fetch(FetchDescriptor<SortingSession>())) ?? []
        return sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// A new session of `assetIDs` for the album, saved. Inserted before its photo list is
    /// attached (see `SortingSession.init(albumID:albumTitle:)`).
    func insertSession(albumID: String, title: String, assetIDs: [String]) -> SortingSession {
        let session = SortingSession(albumID: albumID, albumTitle: title)
        context.insert(session)
        session.reset(assetIDs: assetIDs, albumTitle: title)
        save()
        return session
    }

    /// Writes pending changes to disk. Piq saves after every change, so nothing is lost when it is
    /// killed right after a swipe (a save debounced until the swipes pause loses the whole run of
    /// them). A decision writes only the session's small record, not its photo list, so it costs
    /// about a millisecond to save (simulator) whatever the size of the album.
    func save() {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            Logger.persistence.error("Saving sessions failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func convertSessionsInEarlierLayout() {
        let earlier = allSessions().filter(\.isInEarlierLayout)
        guard !earlier.isEmpty else { return }
        for session in earlier {
            session.convertFromEarlierLayout()
        }
        save()
        Logger.persistence.info("Converted \(earlier.count) sessions saved by an earlier build")
    }
}
