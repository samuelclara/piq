import UIKit

/// Everything Piq needs from the photo library. `PhotoKitLibraryClient` talks to Photos;
/// `MockPhotoLibrary` (DEBUG) backs SwiftUI previews, UI tests and the `-PiqMockLibrary`
/// launch argument.
///
/// Piq only ever sees part of the library: photos (no videos) of the person's own library, not
/// hidden ones, and under limited access only the photos the person allowed. A photo outside
/// that is "not visible", and PhotoKit can't say why: with full access it was deleted (or
/// hidden); with limited access it may simply be outside the selection and still in Photos.
@MainActor
protocol PhotoLibraryClient: AnyObject, Sendable {
    /// Current authorization, read live.
    var access: LibraryAccess { get }
    /// Asks for read/write access if it hasn't been decided yet and returns the outcome.
    func requestAccess() async -> LibraryAccess
    /// Recents, Favorites, then every user album (under limited access, Recents and Favorites
    /// only). Counts and covers include visible photos only.
    func fetchAlbums() async -> [AlbumSummary]
    /// The album's visible photos, oldest first; nil if the album no longer exists.
    func assetIDs(inAlbum albumID: String) async -> [String]?
    /// Filename, capture date and pixel size. Photos that aren't visible are left out.
    func metadata(for assetIDs: [String]) async -> [String: PhotoMetadata]
    /// Moves the photos to Recently Deleted. iPadOS asks the person to confirm first;
    /// throws `PhotoDeletionError.cancelled` when they decline. Photos that aren't visible are
    /// left out of the request and reported as `missing` (gone only if access was full), photos
    /// Photos won't delete as `undeletable`; with nothing left to delete, iPadOS doesn't ask.
    func deleteAssets(_ assetIDs: [String]) async throws -> DeletionReport
    /// Presents the system picker for changing which photos Piq can see (limited access).
    func presentLimitedLibraryPicker()
    /// Called on the main actor, debounced, after the library changes in a way Piq shows:
    /// photos added to or gone from an album, a new capture order, albums added, removed or
    /// renamed. Updates that change none of that (Photos analyzing or syncing photos) don't call it.
    var onChange: (@MainActor () -> Void)? { get set }
}

/// Image loading. Cancelling the calling task cancels the underlying request.
@MainActor
protocol PhotoImageSource: AnyObject, Sendable {
    /// Aspect-fill thumbnail for grids and album covers, sized for `pointSize` at `scale`.
    func thumbnail(for assetID: String, pointSize: CGSize, scale: CGFloat) async -> UIImage?
    /// A fast, low-resolution image, shown blurred until the sharp one arrives.
    func preview(for assetID: String) async -> UIImage?
    /// The sharp image at the display's full resolution, downloaded from iCloud if needed.
    /// `progress` (0...1) is called on the main actor, only while downloading.
    func fullImage(for assetID: String, progress: @escaping @MainActor @Sendable (Double) -> Void) async -> UIImage?
    /// Prefetch hints for upcoming full images.
    func startCachingFullImages(for assetIDs: [String])
    func stopCachingFullImages(for assetIDs: [String])
    /// A sharper image than `fullImage`, for a photo zoomed in on: the original's resolution, up
    /// to a limit. Not cached; the caller holds it only while the photo is zoomed.
    func zoomImage(for assetID: String) async -> UIImage?
}

extension PhotoImageSource {
    /// Sources without anything sharper than the full image serve that.
    func zoomImage(for assetID: String) async -> UIImage? {
        await fullImage(for: assetID) { _ in }
    }
}
