import Observation
import OSLog
import SwiftData
import SwiftUI

/// Screens pushed on top of the album picker.
enum Route: Hashable {
    case sorting(albumID: String)
    case review(albumID: String)

    var albumID: String {
        switch self {
        case .sorting(let albumID), .review(let albumID): albumID
        }
    }
}

/// App-wide state: Photos access, the album list, saved sessions and navigation.
@MainActor
@Observable
final class AppModel {
    let library: any PhotoLibraryClient
    let images: any PhotoImageSource
    let toasts = ToastCenter()
    @ObservationIgnored let container: ModelContainer
    @ObservationIgnored let store: SessionStore

    private(set) var access: LibraryAccess
    private(set) var albums: [AlbumSummary] = []
    private(set) var hasLoadedAlbums = false
    private(set) var isLoadingAlbums = false
    /// Saved sessions by album ID.
    private(set) var sessions: [String: SortingSession] = [:]
    var selectedAlbumID: String?
    var path: [Route] = []
    /// The session being sorted or reviewed (once back on the albums, the last one opened).
    private(set) var activeSession: SessionController?
    private(set) var isOpeningAlbum = false

    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    /// Bumped by every reload, and when Piq itself changes the library. Photos can answer an
    /// older question after a newer one, so work that has been overtaken drops its answers.
    @ObservationIgnored private var reloadGeneration = 0
    /// The controller of every session opened since launch, by album ID. A session that has one
    /// changes only through it.
    @ObservationIgnored private var controllers: [String: SessionController] = [:]

    init(library: any PhotoLibraryClient, images: any PhotoImageSource, container: ModelContainer) {
        self.library = library
        self.images = images
        self.container = container
        self.store = SessionStore(context: container.mainContext)
        self.access = library.access
        library.onChange = { [weak self] in self?.scheduleReload() }
    }

    var selectedAlbum: AlbumSummary? {
        albums.first { $0.id == selectedAlbumID }
    }

    /// "Resume · 38 of 400" data for an album with an unfinished session: its first unsorted
    /// photo, where opening it picks up. An opened session answers from memory.
    func resumePoint(for albumID: String) -> ResumePoint? {
        if let controller = controllers[albumID] {
            return controller.resumePoint
        }
        return sessions[albumID]?.resumePoint
    }

    // MARK: Lifecycle

    /// Runs once at launch: asks for Photos access the first time, then loads the albums.
    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        if library.access == .notDetermined {
            access = await library.requestAccess()
        } else {
            access = library.access
        }
        await reloadAlbums()
    }

    /// Re-reads the authorization status, e.g. when coming back from Settings. Without access,
    /// the open session closes (back to the picker, which explains); every session stays saved
    /// as it is and can be resumed once access is back.
    func refreshAccess() async {
        guard hasStarted, library.access != access else { return }
        let couldRead = access.canRead
        access = library.access
        if access.canRead, !couldRead {
            // Placeholder tiles while the albums load, rather than "No albums yet".
            hasLoadedAlbums = false
        }
        await reloadAlbums()
    }

    /// Writes pending session changes now (the app is going to the background).
    func saveNow() {
        store.save()
    }

    // MARK: Albums

    /// Reloads the albums and brings every saved session in line with the library. Closes the
    /// open session if Piq can no longer read Photos or its album is gone.
    func reloadAlbums() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        guard access.canRead else {
            albums = []
            isLoadingAlbums = false
            hasLoadedAlbums = true
            leaveOpenSession()
            return
        }
        isLoadingAlbums = true
        let fetched = await library.fetchAlbums()
        guard generation == reloadGeneration else { return }
        albums = fetched
        isLoadingAlbums = false
        hasLoadedAlbums = true
        leaveOpenSessionIfItsAlbumIsGone()
        await reconcileSessions(generation)
        guard generation == reloadGeneration else { return }
        if let selected = selectedAlbumID, fetched.contains(where: { $0.id == selected }) {
            return
        }
        selectedAlbumID = defaultSelection()
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            await self?.reloadAlbums()
        }
    }

    /// Piq itself just deleted photos (it emptied a trash). Answers Photos gave before that are
    /// out of date: whatever waits on one drops it, and a fresh reload runs.
    private func photosDeletedByPiq() {
        reloadGeneration += 1
        scheduleReload()
    }

    /// The album of the unfinished session the person worked on last, if there is one.
    private func defaultSelection() -> String? {
        store.allSessions().first { session in
            session.resumePoint != nil && albums.contains { $0.id == session.albumID }
        }?.albumID
    }

    /// Drops photos deleted outside Piq from every session (and its trash), queues photos that
    /// were added to the album since, and follows albums renamed in Photos. None of that is the
    /// person's work, so it doesn't change which session they worked on last.
    private func reconcileSessions(_ generation: Int) async {
        // With limited access a photo Photos doesn't list may only be outside the selection.
        let keepsSortedPhotos = access == .limited
        for record in store.allSessions() {
            // An album that isn't listed may only be hidden (limited access), so leave it alone.
            guard let album = albums.first(where: { $0.id == record.albumID }),
                  let ids = await library.assetIDs(inAlbum: record.albumID) else { continue }
            guard generation == reloadGeneration else { return }
            if let controller = controllers[record.albumID] {
                controller.reconcile(withAlbumAssetIDs: ids, keepingSortedPhotos: keepsSortedPhotos)
                controller.rename(album.title)
            } else {
                let old = record.state
                var state = old
                if state.reconcile(albumAssetIDs: ids, keepingSortedPhotos: keepsSortedPhotos) {
                    record.write(state, over: old, touch: false)
                }
                if record.albumTitle != album.title {
                    record.albumTitle = album.title
                }
            }
        }
        // Read the store again: an album opened while this waited on Photos has a session too.
        sessions = Dictionary(store.allSessions().map { ($0.albumID, $0) }, uniquingKeysWith: { first, _ in first })
        store.save()
    }

    // MARK: Sessions and navigation

    /// Starts sorting `album`, or resumes the last session at its first unsorted photo. A finished
    /// session with photos still in the trash opens on the review screen.
    func openAlbum(_ album: AlbumSummary) async {
        guard !isOpeningAlbum, access.canRead else { return }
        isOpeningAlbum = true
        defer { isOpeningAlbum = false }

        let ids = await currentPhotos(inAlbum: album.id)
        // Access went away while Photos answered: the picker explains that now.
        guard access.canRead else { return }
        guard let ids else {
            toasts.show("That album is no longer in Photos", systemImage: "exclamationmark.circle")
            await reloadAlbums()
            return
        }
        guard !ids.isEmpty else {
            toasts.show("There are no photos in \(album.title)", systemImage: "photo")
            return
        }

        let session = prepareSession(for: album, assetIDs: ids)
        activeSession = session
        selectedAlbumID = album.id
        path = [session.state.isComplete ? .review(albumID: album.id) : .sorting(albumID: album.id)]
    }

    /// The album's photos, oldest first, or nil if it no longer exists. A reload that starts
    /// while Photos answers has seen a newer library (one where a photo was deleted, say), so
    /// the question is asked again rather than letting the older answer bring the photo back.
    private func currentPhotos(inAlbum albumID: String) async -> [String]? {
        var answer: [String]?
        for _ in 0..<3 {
            let generation = reloadGeneration
            answer = await library.assetIDs(inAlbum: albumID)
            if generation == reloadGeneration {
                return answer
            }
        }
        // Still being overtaken (a burst of changes): go with the latest answer and check the
        // session against the library once more when it exists.
        scheduleReload()
        return answer
    }

    /// The album's session, up to date with `ids`: created on first open, otherwise resumed
    /// through its controller at its first unsorted photo. One with nothing left to resume starts
    /// over.
    private func prepareSession(for album: AlbumSummary, assetIDs ids: [String]) -> SessionController {
        let session: SessionController
        if let existing = controllers[album.id] ?? store.session(albumID: album.id).map(register) {
            existing.reconcile(withAlbumAssetIDs: ids, keepingSortedPhotos: access == .limited)
            existing.rename(album.title)
            if existing.resumePoint == nil {
                existing.restart(with: ids)
            }
            existing.goToFirstUnsorted()
            existing.markOpened()
            session = existing
        } else {
            session = register(store.insertSession(albumID: album.id, title: album.title, assetIDs: ids))
        }
        sessions[album.id] = session.record
        return session
    }

    /// Wraps `record` in its controller, from now on the only way the session changes.
    private func register(_ record: SortingSession) -> SessionController {
        let controller = SessionController(record: record, store: store, library: library)
        controller.onPhotosDeleted = { [weak self] in self?.photosDeletedByPiq() }
        controllers[record.albumID] = controller
        return controller
    }

    /// Pushes the review screen over the active session's sorting screen. Does nothing unless
    /// that sorting screen is on top (say, when its last decision lands as it closes).
    func showReview() {
        guard let session = activeSession, path.last == .sorting(albumID: session.albumID) else { return }
        path.append(.review(albumID: session.albumID))
    }

    /// Leaves the review screen: back to sorting, at the first unsorted photo, if photos are left;
    /// otherwise to the albums.
    func continueSorting() {
        guard let session = activeSession, !session.state.isComplete else {
            returnToAlbums()
            return
        }
        session.goToFirstUnsorted()
        let sorting = Route.sorting(albumID: session.albumID)
        if path.count >= 2, path[path.count - 2] == sorting {
            path.removeLast()
        } else {
            path = [sorting]
        }
    }

    func returnToAlbums() {
        path = []
        store.save()
    }

    /// Back to the albums from a sorting or review screen.
    private func leaveOpenSession() {
        guard !path.isEmpty else { return }
        returnToAlbums()
    }

    /// Back to the albums, with a word of explanation, when the album on screen is no longer
    /// listed: deleted in Photos, or hidden by limited access. Its session stays saved.
    private func leaveOpenSessionIfItsAlbumIsGone() {
        guard let albumID = path.last?.albumID, !albums.contains(where: { $0.id == albumID }) else { return }
        let title = controllers[albumID]?.albumTitle ?? sessions[albumID]?.albumTitle ?? "That album"
        leaveOpenSession()
        let message = access == .limited ? "\(title) needs full access to Photos" : "\(title) is no longer in Photos"
        toasts.show(message, systemImage: "exclamationmark.circle")
    }

    // MARK: Previews

    #if DEBUG
    /// Fills in loaded state synchronously, for SwiftUI previews and mock launches.
    func preparePreview(albums: [AlbumSummary], selectedAlbumID: String? = nil) {
        hasStarted = true
        access = library.access
        self.albums = albums
        hasLoadedAlbums = true
        self.selectedAlbumID = selectedAlbumID
        sessions = Dictionary(store.allSessions().map { ($0.albumID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Opens a session for `album` synchronously, sorting its first `sortedCount` photos with
    /// `decide`, for SwiftUI previews and mock launches. A session the store already has (an
    /// on-disk mock store) is opened as it is.
    @discardableResult
    func preparePreviewSession(album: AlbumSummary, assetIDs: [String], sortedCount: Int, decide: (String) -> SwipeAction) -> SessionController {
        let session: SessionController
        if let saved = controllers[album.id] ?? store.session(albumID: album.id).map(register) {
            session = saved
        } else {
            var state = SortingState(assetIDs: assetIDs)
            for _ in 0..<sortedCount {
                guard let current = state.currentAssetID else { break }
                state.apply(decide(current))
            }
            let record = store.insertSession(albumID: album.id, title: album.title, assetIDs: assetIDs)
            record.state = state
            store.save()
            session = register(record)
        }
        sessions[album.id] = session.record
        activeSession = session
        selectedAlbumID = album.id
        return session
    }
    #endif
}
