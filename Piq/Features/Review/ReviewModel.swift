import Observation
import SwiftUI

/// The review screen's own state on top of the session: which photos in the trash are selected,
/// their details for the tiles and the preview, and what is open over the screen.
@MainActor
@Observable
final class ReviewModel {
    /// A photo opened in the full-screen preview.
    struct PreviewTarget: Identifiable, Hashable {
        let id: String
    }

    /// Selected photos. Always part of the trash.
    private(set) var selection: Set<String>
    /// Filename, capture time and pixel size of the photos in the trash, by asset ID.
    private(set) var metadata: [String: PhotoMetadata] = [:]
    /// Whether the "Delete 22 photos?" card is open.
    var isConfirmingDelete: Bool
    /// The photo open in the full-screen preview.
    var preview: PreviewTarget?

    init(selection: Set<String> = [], isConfirmingDelete: Bool = false) {
        self.selection = selection
        self.isConfirmingDelete = isConfirmingDelete
    }

    // MARK: Selection

    func isSelected(_ assetID: String) -> Bool {
        selection.contains(assetID)
    }

    /// Whether every photo in `trash` is selected, so the button reads "Deselect all".
    func isEverythingSelected(in trash: Set<String>) -> Bool {
        !trash.isEmpty && trash.isSubset(of: selection)
    }

    func toggle(_ assetID: String) {
        if selection.remove(assetID) == nil {
            selection.insert(assetID)
        }
    }

    /// Selects the whole trash, or clears the selection when everything already is selected.
    func toggleSelectAll(in trash: Set<String>) {
        selection = isEverythingSelected(in: trash) ? [] : trash
    }

    /// Forgets photos that left the trash: restored, deleted, or gone from the library (a
    /// change in Photos). A preview of one of them closes.
    func trashChanged(to trash: Set<String>) {
        if !selection.isSubset(of: trash) {
            selection.formIntersection(trash)
        }
        if let preview, !trash.contains(preview.id) {
            self.preview = nil
        }
        if trash.isEmpty {
            isConfirmingDelete = false
        }
    }

    func showPreview(of assetID: String) {
        preview = PreviewTarget(id: assetID)
    }

    // MARK: Loading

    /// Loads, in one batch, the details of the photos in `trash` that don't have them yet.
    func loadMetadata(for trash: [String], from library: any PhotoLibraryClient) async {
        let missing = trash.filter { metadata[$0] == nil }
        guard !missing.isEmpty else { return }
        let loaded = await library.metadata(for: missing)
        guard !Task.isCancelled else { return }
        metadata.merge(loaded) { _, new in new }
    }

    // MARK: Trash

    /// Takes the selected photos off the trash list. They stay sorted and now count as kept.
    func restoreSelection(in session: SessionController, toasts: ToastCenter) {
        let restoring = selection.intersection(session.state.markedIDs)
        guard !restoring.isEmpty else { return }
        session.restore(restoring)
        selection = []
        toasts.show(ReviewCopy.restored(restoring.count))
    }

    /// Asks Photos to delete everything in the trash (iPadOS asks to confirm once more) and
    /// reports how it went. When the person declines the system prompt, nothing changes. Does
    /// nothing while a request is already under way.
    func emptyTrash(in session: SessionController, toasts: ToastCenter) async {
        guard !session.isEmptyingTrash else { return }
        switch await session.emptyTrash() {
        case let .deleted(count, undeletable):
            if count + undeletable > 0 {
                selection = []
            }
            if let message = ReviewCopy.deleted(count: count, undeletable: undeletable) {
                toasts.show(message, systemImage: count > 0 ? "checkmark" : ReviewCopy.problemSymbol)
            }
        case .cancelled:
            break
        case .failed:
            toasts.show(ReviewCopy.deleteFailed, systemImage: ReviewCopy.problemSymbol)
        }
    }
}

/// The review screen's copy, including the counted strings.
enum ReviewCopy {
    static let title = "Review"
    static let sectionTitle = "Marked for deletion"
    static let sectionHint = "· tap to select"
    static let deleteBody = "They move to Recently Deleted in Photos, where you can still recover them for 30 days. You'll be asked to confirm once more."
    static let deleteFailed = "Couldn't delete the photos"
    static let emptyTitle = "Trash is empty"
    static let emptyBody = "Swipe a photo left while sorting to mark it for deletion. Nothing leaves Photos until you empty the trash."
    /// The full-screen preview couldn't get the sharp image (an iCloud photo while offline, or a
    /// photo that is gone), so it shows the quick preview instead...
    static let previewFailed = "Couldn't load the full-resolution photo"
    /// ...or couldn't load anything at all.
    static let photoFailed = "Couldn't load this photo"
    static let tryAgain = "Try again"
    /// Toast and notice icon when something went wrong.
    static let problemSymbol = "exclamationmark.circle"

    /// "All 400 photos sorted. Check what goes before emptying the trash." once everything is
    /// sorted, otherwise "120 of 400 sorted so far. Nothing is deleted until you empty the trash."
    static func summary(sorted: Int, total: Int) -> String {
        guard sorted >= total else {
            return "\(sorted.formatted()) of \(total.formatted()) sorted so far. Nothing is deleted until you empty the trash."
        }
        let done = switch total {
        case 0: "All photos sorted."
        case 1: "1 photo sorted."
        default: "All \(Copy.photos(total)) sorted."
        }
        return "\(done) Check what goes before emptying the trash."
    }

    /// VoiceOver's name for a photo in the trash: "Photo, IMG_4838.HEIC, 14:32" (just "Photo"
    /// until its details have loaded).
    static func photoLabel(_ metadata: PhotoMetadata?) -> String {
        guard let metadata else { return "Photo" }
        return "Photo, \(metadata.chipText.spoken)"
    }

    /// "Restore 3", or just "Restore" while nothing is selected.
    static func restoreButton(_ selected: Int) -> String {
        selected > 0 ? "Restore \(selected.formatted())" : "Restore"
    }

    /// "3 photos restored"
    static func restored(_ count: Int) -> String {
        "\(Copy.photos(count)) restored"
    }

    /// "Delete 22 photos?"
    static func deleteTitle(_ count: Int) -> String {
        "Delete \(Copy.photos(count))?"
    }

    /// "Delete 22 photos"
    static func deleteButton(_ count: Int) -> String {
        "Delete \(Copy.photos(count))"
    }

    /// "22 photos moved to Recently Deleted", plus " · 2 couldn't be deleted" when Photos kept
    /// some; nil when nothing happened worth reporting.
    static func deleted(count: Int, undeletable: Int) -> String? {
        switch (count, undeletable) {
        case (0, 0):
            return nil
        case (0, _):
            return "\(Copy.photos(undeletable)) couldn't be deleted"
        case (_, 0):
            return "\(Copy.photos(count)) moved to Recently Deleted"
        default:
            return "\(Copy.photos(count)) moved to Recently Deleted · \(undeletable.formatted()) couldn't be deleted"
        }
    }
}
