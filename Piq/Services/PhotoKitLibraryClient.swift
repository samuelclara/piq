import OSLog
@preconcurrency import Photos
import PhotosUI
import UIKit

/// `PhotoLibraryClient` backed by PhotoKit.
@MainActor
final class PhotoKitLibraryClient: NSObject, PhotoLibraryClient {
    /// How long the library must stay quiet after a change before `onChange` fires, so a burst of
    /// changes (an import, an iCloud sync) costs one reload.
    static let debounceInterval: Duration = .milliseconds(300)
    /// Photo details kept at most. Sorting needs a handful at a time and Review the trash, so the
    /// limit only matters in a very long session.
    static let metadataCacheLimit = 2_000

    var onChange: (@MainActor () -> Void)?

    private var isObserving = false
    private var changeDebounce: Task<Void, Never>?
    private var metadataCache: [String: PhotoMetadata] = [:]
    /// Bumped by every change that touches cached details, so details read before it aren't kept.
    private var changeGeneration = 0
    /// What the last album listing showed, to tell changes that matter from background updates.
    private nonisolated let watch = LibraryWatch()

    var access: LibraryAccess {
        LibraryAccess(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAccess() async -> LibraryAccess {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        startObservingIfAllowed()
        return LibraryAccess(status)
    }

    func fetchAlbums() async -> [AlbumSummary] {
        startObservingIfAllowed()
        let watch = watch
        return await Task.detached(priority: .userInitiated) {
            let listing = PhotoKitQueries.albumListing()
            watch.watch(listing.snapshot)
            return listing.albums
        }.value
    }

    func assetIDs(inAlbum albumID: String) async -> [String]? {
        await Task.detached(priority: .userInitiated) { PhotoKitQueries.assetIDs(inAlbum: albumID) }.value
    }

    func metadata(for assetIDs: [String]) async -> [String: PhotoMetadata] {
        // Cached details are taken before loading the others: a library change during the load
        // can evict them, and a photo left out of the answer reads as gone.
        var result: [String: PhotoMetadata] = [:]
        var uncached: [String] = []
        for id in assetIDs {
            if let cached = metadataCache[id] {
                result[id] = cached
            } else {
                uncached.append(id)
            }
        }
        guard !uncached.isEmpty else { return result }
        let generation = changeGeneration
        let loaded = await Task.detached(priority: .userInitiated) { PhotoKitQueries.metadata(for: uncached) }.value
        // Details read while the library changed may be out of date: use them once, don't keep them.
        if generation == changeGeneration {
            if metadataCache.count + loaded.count > Self.metadataCacheLimit {
                metadataCache.removeAll(keepingCapacity: true)
            }
            metadataCache.merge(loaded) { _, new in new }
        }
        result.merge(loaded) { _, new in new }
        return result
    }

    func deleteAssets(_ assetIDs: [String]) async throws -> DeletionReport {
        let plan = await Task.detached(priority: .userInitiated) { PhotoKitQueries.deletionPlan(for: assetIDs) }.value
        let deletable = plan.deletable
        if !deletable.isEmpty {
            do {
                // The block runs on PhotoKit's queue, so it isn't isolated to the main actor.
                try await PHPhotoLibrary.shared().performChanges { @Sendable in
                    PHAssetChangeRequest.deleteAssets(PHAsset.fetchAssets(withLocalIdentifiers: deletable, options: nil))
                }
            } catch {
                let nsError = error as NSError
                if Self.isDeclinedPrompt(nsError) {
                    Logger.photos.info("Deleting \(deletable.count) photos was declined (\(nsError.domain, privacy: .public) \(nsError.code))")
                    throw PhotoDeletionError.cancelled
                }
                Logger.photos.error("Deleting \(deletable.count) photos failed: \(error.localizedDescription, privacy: .public)")
                throw PhotoDeletionError.failed(error.localizedDescription)
            }
        }
        return DeletionReport(deleted: deletable, missing: plan.missing, undeletable: plan.undeletable)
    }

    func presentLimitedLibraryPicker() {
        guard let presenter = UIApplication.shared.piqTopViewController else { return }
        // The selection reaches Piq as a library change; the handler can run on any queue.
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: presenter) { @Sendable _ in }
    }

    /// Declining the system prompt reports `PHPhotosError.userCancelled`, whose code (3072) is
    /// also Cocoa's `NSUserCancelledError`.
    nonisolated static func isDeclinedPrompt(_ error: NSError) -> Bool {
        error.code == PHPhotosError.Code.userCancelled.rawValue
            && (error.domain == PHPhotosErrorDomain || error.domain == NSCocoaErrorDomain)
    }

    // MARK: Change observation

    /// Registering before access is granted would trigger the permission prompt, so wait.
    private func startObservingIfAllowed() {
        guard !isObserving, access.canRead else { return }
        PHPhotoLibrary.shared().register(self)
        isObserving = true
    }

    /// Changes to what Piq lists reload it, debounced. Other changes (Photos analyzing or
    /// syncing photos, updating an album's derived data a moment after a change) only drop the
    /// cached details of the photos they touched. Called on the main actor for every PhotoKit
    /// notice (internal so tests can land one at a chosen moment).
    func libraryChanged(_ verdict: LibraryWatch.Verdict) {
        guard verdict.isRelevant else {
            guard !verdict.changedAssetIDs.isEmpty else { return }
            changeGeneration += 1
            for id in verdict.changedAssetIDs { metadataCache[id] = nil }
            return
        }
        changeGeneration += 1
        metadataCache.removeAll()
        changeDebounce?.cancel()
        changeDebounce = Task { [weak self] in
            try? await Task.sleep(for: Self.debounceInterval)
            guard !Task.isCancelled else { return }
            self?.onChange?()
        }
    }
}

extension PhotoKitLibraryClient: PHPhotoLibraryChangeObserver {
    /// Called on PhotoKit's serial queue, which is where the change is weighed.
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        let verdict = watch.absorb(changeInstance)
        Task { @MainActor [weak self] in self?.libraryChanged(verdict) }
    }
}

/// The fetch results behind the last album listing. A `PHChange` measured against them says
/// whether anything Piq lists changed: photos added to or gone from an album (deleted, hidden,
/// moved out, picked or unpicked under limited access), a new capture order, or albums added,
/// removed, renamed or reordered. Photos also reports background updates (analysis, iCloud,
/// album data refreshed a moment after a change) that change none of that.
/// Used from PhotoKit's change queue and from album listings, behind a lock.
final class LibraryWatch: @unchecked Sendable {
    /// PhotoKit fetch results are immutable snapshots, safe to read from any thread.
    struct Snapshot: @unchecked Sendable {
        /// Each listed album's photos, as the listing fetched them.
        var photos: [PHFetchResult<PHAsset>] = []
        /// The album tree: the top level and every folder.
        var folders: [PHFetchResult<PHCollection>] = []
        /// Every regular album, wherever it is.
        var albums: PHFetchResult<PHAssetCollection>?
        /// Album and folder titles by identifier.
        var titles: [String: String] = [:]
    }

    struct Verdict: Sendable {
        /// Something Piq lists changed: reload.
        var isRelevant: Bool
        /// Photos whose properties changed (their cached details may be out of date).
        var changedAssetIDs: Set<String>
    }

    private let lock = NSLock()
    private var snapshot: Snapshot?

    func watch(_ snapshot: Snapshot) {
        lock.withLock { self.snapshot = snapshot }
    }

    /// Weighs `change` and moves the watched results past it.
    func absorb(_ change: PHChange) -> Verdict {
        lock.withLock {
            guard var current = snapshot else { return Verdict(isRelevant: true, changedAssetIDs: []) }
            var verdict = Verdict(isRelevant: false, changedAssetIDs: [])
            for index in current.photos.indices {
                guard let details = change.changeDetails(for: current.photos[index]) else { continue }
                current.photos[index] = details.fetchResultAfterChanges
                verdict.isRelevant = verdict.isRelevant || Self.reshapes(details)
                verdict.changedAssetIDs.formUnion(details.changedObjects.map(\.localIdentifier))
            }
            for index in current.folders.indices {
                guard let details = change.changeDetails(for: current.folders[index]) else { continue }
                current.folders[index] = details.fetchResultAfterChanges
                verdict.isRelevant = verdict.isRelevant || Self.reshapes(details) || Self.renames(details.changedObjects, in: &current.titles)
            }
            if let albums = current.albums, let details = change.changeDetails(for: albums) {
                current.albums = details.fetchResultAfterChanges
                verdict.isRelevant = verdict.isRelevant || Self.reshapes(details) || Self.renames(details.changedObjects, in: &current.titles)
            }
            snapshot = current
            return verdict
        }
    }

    /// Objects came or went, or the order changed (or PhotoKit can't say).
    private static func reshapes<T: AnyObject>(_ details: PHFetchResultChangeDetails<T>) -> Bool {
        !details.hasIncrementalChanges || !details.insertedObjects.isEmpty || !details.removedObjects.isEmpty || details.hasMoves
    }

    /// Whether any of `collections` has a new title, noting the new titles.
    private static func renames(_ collections: [some PHCollection], in titles: inout [String: String]) -> Bool {
        var renamed = false
        for collection in collections {
            let title = collection.localizedTitle ?? ""
            if titles[collection.localIdentifier] != title {
                titles[collection.localIdentifier] = title
                renamed = true
            }
        }
        return renamed
    }
}

extension LibraryAccess {
    init(_ status: PHAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .authorized: self = .authorized
        case .limited: self = .limited
        case .denied: self = .denied
        case .restricted: self = .restricted
        @unknown default: self = .denied
        }
    }
}

/// Synchronous PhotoKit queries, run off the main thread.
enum PhotoKitQueries {
    struct DeletionPlan: Sendable {
        var deletable: [String] = []
        var missing: [String] = []
        var undeletable: [String] = []
    }

    /// Photos only (no videos), from the person's own library: shared-album and
    /// computer-synced photos can't be deleted, so Piq leaves them out. A burst shows as its one
    /// representative photo, as in Photos. Hidden photos never show: PhotoKit doesn't give them
    /// to apps (iOS 26 locks the Hidden album), so one hidden mid-session leaves the session.
    static func photoOptions(oldestFirst: Bool? = nil) -> PHFetchOptions {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.includeAssetSourceTypes = [.typeUserLibrary]
        if let oldestFirst {
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: oldestFirst)]
        }
        return options
    }

    /// The album list and the fetch results it came from (for `LibraryWatch`).
    struct AlbumListing: @unchecked Sendable {
        var albums: [AlbumSummary] = []
        var snapshot = LibraryWatch.Snapshot()
    }

    /// The album list alone, as `albumListing()` makes it.
    static func albums() -> [AlbumSummary] {
        albumListing().albums
    }

    /// Recents and Favorites, then the person's albums in the order Photos lists them. Under
    /// limited access, Recents and Favorites only: PhotoKit still lists every album then, but
    /// holding just the photos the person allowed (none, for most), and a saved session must not
    /// be measured against that partial view of its album.
    ///
    /// Each of the person's albums gets its `creationRank` (for the picker's "Date created"):
    /// its place in PhotoKit's list of regular albums fetched with no sort descriptor, which
    /// comes in the order the albums were made, oldest first. Apple doesn't document that
    /// order, but it is the only public trace of when an album was made that we found:
    /// `PHAssetCollection` has no creation date, `creationDate` as a collection sort key or
    /// predicate raises "Unsupported sort descriptor/predicate in fetch options", and
    /// `startDate`/`endDate` are the capture range of the album's photos, which Photos fills in
    /// later (nil for an album made a moment ago). Checked on iPadOS 26.5 by `PickerRealLibraryTests`: the order follows
    /// when albums were made, not their titles, their photos, renames, or their place in a
    /// folder. Not checked (the simulator has no iCloud Photos): an album that arrives through
    /// iCloud Photos probably counts from when it reached this device.
    static func albumListing() -> AlbumListing {
        var listing = AlbumListing()
        // PhotoKit titles these in the app's language, the way Photos does; the fallbacks are
        // the English titles it uses.
        let smartAlbums: [(PHAssetCollectionSubtype, AlbumSummary.Kind, String)] = [
            (.smartAlbumUserLibrary, .recents, "Recents"),
            (.smartAlbumFavorites, .favorites, "Favorites"),
        ]
        for (subtype, kind, fallbackTitle) in smartAlbums {
            if let collection = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil).firstObject {
                listing.add(collection, kind: kind, title: collection.localizedTitle ?? fallbackTitle)
            }
        }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) != .limited else { return listing }
        for (collection, creationRank) in userAlbums(into: &listing.snapshot) {
            listing.add(collection, kind: .user, title: collection.localizedTitle ?? "Untitled album", creationRank: creationRank)
        }
        return listing
    }

    /// The person's own albums in Photos' order, an album inside a folder taking the folder's
    /// place, each with its place in the order the albums were made (see `albumListing()`).
    /// Shared, synced and imported albums are left out: Piq can't delete their photos.
    private static func userAlbums(into snapshot: inout LibraryWatch.Snapshot) -> [(PHAssetCollection, creationRank: Int?)] {
        var albums: [PHAssetCollection] = []
        var listed = Set<String>()
        var folders: [PHFetchResult<PHCollection>] = []
        var titles: [String: String] = [:]
        func add(_ album: PHAssetCollection) {
            if album.assetCollectionSubtype == .albumRegular, listed.insert(album.localIdentifier).inserted {
                albums.append(album)
            }
        }
        func walk(_ collections: PHFetchResult<PHCollection>) {
            folders.append(collections)
            collections.enumerateObjects { collection, _, _ in
                titles[collection.localIdentifier] = collection.localizedTitle ?? ""
                if let album = collection as? PHAssetCollection {
                    add(album)
                } else if let folder = collection as? PHCollectionList {
                    walk(PHCollection.fetchCollections(in: folder, options: nil))
                }
            }
        }
        walk(PHCollectionList.fetchTopLevelUserCollections(with: nil))
        // An album PhotoKit lists outside the folder tree still shows, after the others.
        // With no sort descriptor, in the order the albums were made.
        let regular = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        var creationRanks: [String: Int] = [:]
        regular.enumerateObjects { album, index, _ in
            titles[album.localIdentifier] = album.localizedTitle ?? ""
            creationRanks[album.localIdentifier] = index
            add(album)
        }
        snapshot.folders = folders
        snapshot.albums = regular
        snapshot.titles = titles
        return albums.map { ($0, creationRanks[$0.localIdentifier]) }
    }

    static func assetIDs(inAlbum albumID: String) -> [String]? {
        guard let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject else {
            return nil
        }
        let assets = PHAsset.fetchAssets(in: collection, options: photoOptions(oldestFirst: true))
        var ids: [String] = []
        ids.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in ids.append(asset.localIdentifier) }
        return ids
    }

    /// The name is the original file's (the `.photo` resource: a Live Photo's still, not its
    /// video; the original, not an edit's "FullSizeRender").
    static func metadata(for ids: [String]) -> [String: PhotoMetadata] {
        var result: [String: PhotoMetadata] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in
            let resources = PHAssetResource.assetResources(for: asset)
            let original = resources.first { $0.type == .photo } ?? resources.first
            result[asset.localIdentifier] = PhotoMetadata(
                id: asset.localIdentifier,
                filename: original?.originalFilename ?? "Photo",
                creationDate: asset.creationDate,
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight
            )
        }
        return result
    }

    static func deletionPlan(for ids: [String]) -> DeletionPlan {
        var plan = DeletionPlan()
        var found = Set<String>()
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in
            found.insert(asset.localIdentifier)
            if asset.canPerform(.delete) {
                plan.deletable.append(asset.localIdentifier)
            } else {
                plan.undeletable.append(asset.localIdentifier)
            }
        }
        plan.missing = ids.filter { !found.contains($0) }
        return plan
    }
}

private extension PhotoKitQueries.AlbumListing {
    /// Lists `collection`: its photos newest first give the count, the cover (the newest) and
    /// the cover's capture date.
    mutating func add(_ collection: PHAssetCollection, kind: AlbumSummary.Kind, title: String, creationRank: Int? = nil) {
        let photos = PHAsset.fetchAssets(in: collection, options: PhotoKitQueries.photoOptions(oldestFirst: false))
        let newest = photos.firstObject
        albums.append(AlbumSummary(
            id: collection.localIdentifier,
            title: title,
            kind: kind,
            photoCount: photos.count,
            coverAssetID: newest?.localIdentifier,
            creationRank: creationRank,
            newestPhotoDate: newest?.creationDate
        ))
        snapshot.photos.append(photos)
    }
}

extension UIApplication {
    /// The view controller on top of the foreground window, for presenting UIKit-only pickers.
    var piqTopViewController: UIViewController? {
        let scenes = connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
