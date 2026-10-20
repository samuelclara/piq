#if DEBUG
import UIKit

/// An in-memory photo library for SwiftUI previews, UI tests and the `-PiqMockLibrary` launch
/// argument. Its photos are the "MockPhotoNN" images in Preview Assets.
@MainActor
final class MockPhotoLibrary: PhotoLibraryClient {
    enum DeletionBehavior: String {
        case succeed
        /// Behaves as if the person tapped "Don't Allow" in the system prompt.
        case cancel
        case fail
    }

    struct Album {
        let id: String
        let title: String
        let kind: AlbumSummary.Kind
        var assetIDs: [String]
    }

    static let icelandAlbumID = "mock-album-iceland"
    static let lisbonAlbumID = "mock-album-lisbon"
    static let recentsAlbumID = "mock-album-recents"
    /// How long the stand-in for the system deletion prompt takes to answer.
    nonisolated static let defaultDeletionDelay: Duration = .milliseconds(350)

    /// Where a library that remembers its changes keeps the photos and albums deleted from it.
    private static let deletedAssetsKey = "PiqMockDeletedAssetIDs"
    private static let deletedAlbumsKey = "PiqMockDeletedAlbumIDs"

    var onChange: (@MainActor () -> Void)?
    /// Changing it, as in Settings, changes what Piq can see: limited access hides the user
    /// albums and all but a few photos. Piq notices when it next reads it.
    var access: LibraryAccess {
        didSet {
            if access != oldValue { build() }
        }
    }
    var deletionBehavior: DeletionBehavior = .succeed
    var deletionDelay: Duration = defaultDeletionDelay

    private(set) var albums: [Album] = []
    private var assets: [String: (imageName: String, metadata: PhotoMetadata)] = [:]
    /// Photos and albums deleted, by Piq or "elsewhere". They stay deleted when access changes.
    private var deletedAssetIDs: Set<String> = []
    private var deletedAlbumIDs: Set<String> = []
    private let remembersChanges: Bool
    /// Numbers the photos: their IDs, filenames and capture times follow it.
    private var nextSerial = 0

    /// - Parameters:
    ///   - access: `.limited` hides the user albums and all but a few photos, the way PhotoKit does.
    ///   - remembersChanges: Keeps the deleted photos and albums deleted across launches (in the
    ///     app's user defaults), like a real library, for the on-disk mock store.
    init(access: LibraryAccess = .authorized, remembersChanges: Bool = false) {
        self.access = access
        self.remembersChanges = remembersChanges
        if remembersChanges {
            let defaults = UserDefaults.standard
            deletedAssetIDs = Set(defaults.stringArray(forKey: Self.deletedAssetsKey) ?? [])
            deletedAlbumIDs = Set(defaults.stringArray(forKey: Self.deletedAlbumsKey) ?? [])
        }
        build()
    }

    /// Forgets what libraries that remember their changes have deleted.
    static func forgetRememberedChanges() {
        UserDefaults.standard.removeObject(forKey: deletedAssetsKey)
        UserDefaults.standard.removeObject(forKey: deletedAlbumsKey)
    }

    // MARK: Synchronous accessors (previews, tests)

    func album(_ id: String) -> AlbumSummary? { albumSummaries().first { $0.id == id } }

    func albumSummaries() -> [AlbumSummary] {
        guard access.canRead else { return [] }
        return albums.map { album in
            AlbumSummary(id: album.id, title: album.title, kind: album.kind, photoCount: album.assetIDs.count, coverAssetID: album.assetIDs.last)
        }
    }

    func photoIDs(inAlbum id: String) -> [String] { albums.first { $0.id == id }?.assetIDs ?? [] }

    func imageName(for assetID: String) -> String? { assets[assetID]?.imageName }

    // MARK: PhotoLibraryClient

    func requestAccess() async -> LibraryAccess {
        if access == .notDetermined {
            access = .authorized
        }
        return access
    }

    func fetchAlbums() async -> [AlbumSummary] { albumSummaries() }

    func assetIDs(inAlbum albumID: String) async -> [String]? {
        guard access.canRead else { return nil }
        return albums.first { $0.id == albumID }?.assetIDs
    }

    func metadata(for assetIDs: [String]) async -> [String: PhotoMetadata] {
        var result: [String: PhotoMetadata] = [:]
        for id in assetIDs {
            if let asset = assets[id] { result[id] = asset.metadata }
        }
        return result
    }

    func deleteAssets(_ assetIDs: [String]) async throws -> DeletionReport {
        // Stand-in for the system confirmation.
        try? await Task.sleep(for: deletionDelay)
        switch deletionBehavior {
        case .cancel:
            throw PhotoDeletionError.cancelled
        case .fail:
            throw PhotoDeletionError.failed("The operation couldn't be completed.")
        case .succeed:
            let existing = assetIDs.filter { assets[$0] != nil }
            let missing = assetIDs.filter { assets[$0] == nil }
            remove(Set(existing))
            return DeletionReport(deleted: existing, missing: missing, undeletable: [])
        }
    }

    func presentLimitedLibraryPicker() {}

    // MARK: Changes made elsewhere

    /// Simulates photos being deleted outside Piq.
    func remove(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        deletedAssetIDs.formUnion(ids)
        dropDeleted()
        changed()
    }

    /// Simulates an album being deleted in Photos. Its photos stay in the library.
    func removeAlbum(_ id: String) {
        deletedAlbumIDs.insert(id)
        dropDeleted()
        changed()
    }

    /// Simulates `count` new photos, taken after all the others, being added to an album (and so
    /// to Recents). Returns their IDs. A change of access forgets them.
    @discardableResult
    func addPhotos(_ count: Int, toAlbum albumID: String) -> [String] {
        guard count > 0, let index = albums.firstIndex(where: { $0.id == albumID }) else { return [] }
        let ids = (0..<count).map { _ in makeAsset() }
        albums[index].assetIDs += ids
        if let recents = albums.firstIndex(where: { $0.kind == .recents }), recents != index {
            albums[recents].assetIDs += ids
        }
        changed()
        return ids
    }

    // MARK: Building

    /// Pixel sizes of MockPhoto01...16 (1-based).
    private static let imageSizes: [(Int, Int)] = [
        (1500, 1000), (1500, 1000), (1000, 1500), (1500, 1000), (1400, 1050), (1500, 1000), (1000, 1500), (1500, 1000),
        (1400, 1050), (1500, 1000), (1500, 1000), (1400, 1050), (1000, 1500), (1500, 1000), (1500, 1000), (1500, 1000),
    ]

    /// When the first photo was taken (12 Sep 2026); each next one is 97 seconds later.
    private static let firstCaptureDate = Date(timeIntervalSince1970: 1_789_200_000)

    private func build() {
        assets = [:]
        albums = []
        nextSerial = 0
        guard access.canRead else { return }

        // A 400-photo import, two smaller albums and an empty one.
        let groups: [(id: String, title: String, count: Int)] = [
            (Self.icelandAlbumID, "Iceland 2026", 400),
            (Self.lisbonAlbumID, "Weekend in Lisbon", 36),
            ("mock-album-family", "Family", 18),
            ("mock-album-drafts", "Drafts", 0),
        ]
        var userAlbums: [Album] = []
        var everything: [String] = []
        for group in groups {
            let ids = (0..<group.count).map { _ in makeAsset() }
            userAlbums.append(Album(id: group.id, title: group.title, kind: .user, assetIDs: ids))
            everything += ids
        }

        if access == .limited {
            // Limited access: only the photos the person picked, and no user albums.
            let allowed = Array(everything.prefix(30)) + Array(everything.dropFirst(400).prefix(6))
            let allowedSet = Set(allowed)
            for id in assets.keys where !allowedSet.contains(id) { assets[id] = nil }
            albums = [
                Album(id: Self.recentsAlbumID, title: "Recents", kind: .recents, assetIDs: allowed),
                Album(id: "mock-album-favorites", title: "Favorites", kind: .favorites, assetIDs: allowed.enumerated().filter { $0.offset % 5 == 0 }.map(\.element)),
            ]
        } else {
            albums = [
                Album(id: Self.recentsAlbumID, title: "Recents", kind: .recents, assetIDs: everything),
                Album(id: "mock-album-favorites", title: "Favorites", kind: .favorites, assetIDs: everything.enumerated().filter { $0.offset % 9 == 0 }.map(\.element)),
            ] + userAlbums
        }
        dropDeleted()
    }

    /// Creates the next photo in the library and returns its ID.
    private func makeAsset() -> String {
        let serial = nextSerial
        nextSerial += 1
        let id = String(format: "mock-asset-%04d", serial)
        let imageIndex = (serial * 7) % Self.imageSizes.count
        let size = Self.imageSizes[imageIndex]
        let metadata = PhotoMetadata(
            id: id,
            filename: String(format: "IMG_%04d.HEIC", 4401 + serial),
            creationDate: Self.firstCaptureDate.addingTimeInterval(Double(serial) * 97),
            pixelWidth: size.0,
            pixelHeight: size.1
        )
        assets[id] = (String(format: "MockPhoto%02d", imageIndex + 1), metadata)
        return id
    }

    private func dropDeleted() {
        guard !deletedAssetIDs.isEmpty || !deletedAlbumIDs.isEmpty else { return }
        for id in deletedAssetIDs { assets[id] = nil }
        albums.removeAll { deletedAlbumIDs.contains($0.id) }
        for index in albums.indices {
            albums[index].assetIDs.removeAll { deletedAssetIDs.contains($0) }
        }
    }

    /// Remembers the deletions (if this library does) and tells Piq, the way PhotoKit's change
    /// observer does a moment after the change.
    private func changed() {
        if remembersChanges {
            UserDefaults.standard.set(deletedAssetIDs.sorted(), forKey: Self.deletedAssetsKey)
            UserDefaults.standard.set(deletedAlbumIDs.sorted(), forKey: Self.deletedAlbumsKey)
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            self?.onChange?()
        }
    }
}
#endif
