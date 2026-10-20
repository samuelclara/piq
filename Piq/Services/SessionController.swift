import Foundation
import Observation
import OSLog

/// One album's sorting session while it is open, shared by the sorting and review screens.
/// Every change is written through to SwiftData and saved right away, so the session survives
/// Piq being quit, or killed, at any moment.
///
/// `AppModel` keeps one controller per session and changes a session only through it, so no
/// second, stale copy of a session can overwrite it.
@MainActor
@Observable
final class SessionController: Identifiable {
    enum Change: Equatable {
        case decided(SortDecision)
        case undone(SortDecision)
        case restored(count: Int)
        case trashEmptied(count: Int)
        case reconciled
    }

    enum TrashOutcome: Equatable {
        /// `count` photos moved to Recently Deleted; `undeletable` ones stay in the trash.
        case deleted(count: Int, undeletable: Int)
        /// The person declined the system confirmation; nothing changed.
        case cancelled
        case failed(String)
    }

    let albumID: String
    private(set) var albumTitle: String
    private(set) var state: SortingState
    /// The most recent change, so screens can animate in the right direction.
    private(set) var lastChange: Change?
    private(set) var isEmptyingTrash = false

    /// The saved session. Change it only through this controller, and read `state` rather than
    /// the record: `state` is the same, in memory.
    @ObservationIgnored let record: SortingSession
    /// Called after Piq itself deleted photos from the library, so the app can drop answers
    /// Photos gave before the deletion and reload.
    @ObservationIgnored var onPhotosDeleted: (@MainActor () -> Void)?
    @ObservationIgnored private let store: SessionStore
    @ObservationIgnored private let library: any PhotoLibraryClient

    init(record: SortingSession, store: SessionStore, library: any PhotoLibraryClient) {
        self.albumID = record.albumID
        self.albumTitle = record.albumTitle
        self.state = record.state
        self.record = record
        self.store = store
        self.library = library
    }

    nonisolated var id: String { albumID }

    /// "Resume · 38 of 400" data, or nil when there is nothing to resume. Read from memory: the
    /// record holds the same.
    var resumePoint: ResumePoint? { state.resumePoint }

    // MARK: Sorting

    /// Applies `action` to the photo on screen. Pass the asset the person was looking at, so a
    /// library change underneath can't make the decision land on a different photo.
    @discardableResult
    func decide(_ action: SwipeAction, for assetID: String? = nil) -> SortDecision? {
        if let assetID, assetID != state.currentAssetID { return nil }
        guard let decision = state.apply(action) else { return nil }
        lastChange = .decided(decision)
        record.recordDecision(action, at: state.sortedCount - 1, inTrash: state.isMarked(decision.assetID))
        store.save()
        return decision
    }

    /// Goes back to the previous photo and reverses its decision.
    @discardableResult
    func undo() -> SortDecision? {
        guard let decision = state.undo() else { return nil }
        lastChange = .undone(decision)
        record.keepDecisions(state.sortedCount)
        store.save()
        return decision
    }

    // MARK: Trash

    /// Takes photos off the trash list. They stay sorted and count as kept.
    func restore(_ assetIDs: Set<String>) {
        let count = assetIDs.intersection(state.markedIDs).count
        guard count > 0 else { return }
        let old = state
        state.unmark(assetIDs)
        lastChange = .restored(count: count)
        persist(over: old, touch: true)
    }

    /// Asks Photos to delete everything in the trash. iPadOS shows its own confirmation; if the
    /// person declines, the trash is left exactly as it was.
    ///
    /// The session can change while the prompt is up (a library change reconciles it, say), so
    /// the outcome applies to the session as it is when Photos answers. Until then nothing is
    /// saved as deleted: if Piq is killed meanwhile, the next launch finds the photos either
    /// still in Photos (and in the trash) or gone (and dropped by the library check).
    func emptyTrash() async -> TrashOutcome {
        let ids = state.markedInOrder
        guard !ids.isEmpty, !isEmptyingTrash else { return .deleted(count: 0, undeletable: 0) }
        isEmptyingTrash = true
        defer { isEmptyingTrash = false }
        let accessWhenAsked = library.access
        do {
            let report = try await library.deleteAssets(ids)
            // Photos reports the photos it can't see as missing. Only with full access, from the
            // question to the answer, does that mean they are gone. With limited access it can't
            // tell a photo outside the person's selection from one that is gone, and without
            // access it sees none: such photos stay in the trash and count as not deleted.
            let seesEverything = accessWhenAsked == .authorized && library.access == .authorized
            let unconfirmed = seesEverything ? [] : Set(report.missing)
            let old = state
            state.remove(Set(report.deleted).union(report.missing).subtracting(unconfirmed))
            lastChange = .trashEmptied(count: report.deleted.count)
            persist(over: old, touch: true)
            if !report.deleted.isEmpty {
                onPhotosDeleted?()
            }
            return .deleted(count: report.deleted.count, undeletable: report.undeletable.count + unconfirmed.count)
        } catch PhotoDeletionError.cancelled {
            return .cancelled
        } catch PhotoDeletionError.failed(let message) {
            return .failed(message)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: Library changes

    /// Drops photos that left the album and queues new ones (see `SortingState.reconcile`). A
    /// change the library made, so the session doesn't become the one worked on last.
    func reconcile(withAlbumAssetIDs ids: [String], keepingSortedPhotos: Bool = false) {
        let old = state
        var next = state
        guard next.reconcile(albumAssetIDs: ids, keepingSortedPhotos: keepingSortedPhotos) else { return }
        state = next
        lastChange = .reconciled
        persist(over: old, touch: false)
    }

    /// Follows the album's name in Photos (not the person's work either).
    func rename(_ title: String) {
        guard title != albumTitle else { return }
        albumTitle = title
        record.albumTitle = title
        store.save()
    }

    /// Starts over with `ids` (the album's photos now), for a session with nothing left to
    /// resume: never started, or everything sorted and the trash emptied.
    func restart(with ids: [String]) {
        record.reset(assetIDs: ids, albumTitle: albumTitle)
        state = record.state
        lastChange = nil
        store.save()
    }

    /// Makes the session the one the person worked on last (the picker selects it on launch).
    func markOpened() {
        record.updatedAt = .now
        store.save()
    }

    /// Writes the change from `old` (what the record holds) to `state` through, and saves it.
    /// `touch`: the person made the change (see `SortingSession.updatedAt`).
    private func persist(over old: SortingState, touch: Bool) {
        record.write(state, over: old, touch: touch)
        store.save()
    }
}
