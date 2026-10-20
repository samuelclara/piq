import CoreLocation
@preconcurrency import Photos
import XCTest

/// The simulator photo library the PhotoKit end-to-end tests run on, and the setup that arranges
/// it. `PhotoKitIntegrationTests` explains how to prepare a simulator.
///
/// The media (`Tools/PhotoKitE2E/gen_media.swift`, imported with `xcrun simctl addmedia` by
/// `Tools/PhotoKitE2E/prepare-library.sh`) is 60 photos E2E_1001...E2E_1060 with distinct
/// capture dates over 10 and 11 Oct 2026, a small E2E_SMALL, and two videos.
/// `prepare()` arranges, by original filename:
///
/// - "E2E Trip": 25 photos, the first 25 of E2E_1001...E2E_1050 still in the library (deleting
///   tests use them up; the next setup tops the album up), added in filename order, which is not
///   capture order. Also the video E2E_CLIP1.
/// - "E2E Empty": no photos, only the video E2E_CLIP2, so it lists as "0 photos" with no cover.
/// - "E2E Nested", inside the folder "E2E Folder": E2E_1051...E2E_1055.
/// - Favorites: 8 photos (every third of E2E_1003...E2E_1050 still in the library) and E2E_CLIP1.
/// - E2E_1056 is hidden. Hiding asks for confirmation ("Allow … to hide this photo?"), which a
///   hosted test can't answer, so `PhotoKitEndToEndTests.test00GrantFullAccess` hides it. From
///   then on PhotoKit doesn't show it to apps at all (iOS 26 locks the Hidden album), not even
///   with `includeHiddenAssets`.
///
/// The setup is idempotent: it reuses albums by title and only changes what differs. Creating
/// albums and folders, album membership and favorites need no confirmation, so a hosted test can
/// do it. Nothing here deletes anything.
@MainActor
enum PhotoKitTestLibrary {
    static let tripTitle = "E2E Trip"
    static let emptyTitle = "E2E Empty"
    static let folderTitle = "E2E Folder"
    static let nestedTitle = "E2E Nested"
    static let tripPhotoCount = 25
    static let favoritePhotoCount = 8
    static let tripVideoName = "E2E_CLIP1.MOV"
    static let emptyVideoName = "E2E_CLIP2.MOV"
    static let hiddenPhotoName = "E2E_1056.JPG"

    /// One E2E photo or video as PhotoKit has it.
    struct Item: Hashable {
        let id: String
        /// Original filename, e.g. "E2E_1005.HEIC".
        let filename: String
        let isVideo: Bool
        let isFavorite: Bool
        let isHidden: Bool
        let creationDate: Date?
        let pixelWidth: Int
        let pixelHeight: Int

        /// 1001 for "E2E_1001.JPG"; 0 for the videos.
        var number: Int { Int(filename.dropFirst(4).prefix(4)) ?? 0 }
    }

    /// The arranged library.
    struct Layout {
        let trip: PHAssetCollection
        let empty: PHAssetCollection
        let nested: PHAssetCollection
        let folder: PHCollectionList
        /// "E2E Trip"'s photos, by filename.
        let tripPhotos: [Item]
        let tripVideo: Item
        let emptyVideo: Item
        let nestedPhotos: [Item]
        /// Favorite photos (not the video).
        let favoritePhotos: [Item]
    }

    struct SetupError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Whether the gated end-to-end tests should run (`TEST_RUNNER_PIQ_E2E=1`).
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["PIQ_E2E"] == "1"
    }

    // MARK: Reading

    /// Every E2E photo and video in the library, hidden ones included (not those in Recently
    /// Deleted), by filename.
    static func items() -> [Item] {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        var items: [Item] = []
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
            let resources = PHAssetResource.assetResources(for: asset)
            let primary = resources.first { $0.type == .photo || $0.type == .video } ?? resources.first
            guard let name = primary?.originalFilename, name.hasPrefix("E2E_") else { return }
            items.append(Item(
                id: asset.localIdentifier,
                filename: name,
                isVideo: asset.mediaType == .video,
                isFavorite: asset.isFavorite,
                isHidden: asset.isHidden,
                creationDate: asset.creationDate,
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight
            ))
        }
        return items.sorted { $0.filename < $1.filename }
    }

    /// The regular album titled `title`, wherever it is (top level or in a folder).
    static func album(titled title: String) -> PHAssetCollection? {
        var found: PHAssetCollection?
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil).enumerateObjects { collection, _, stop in
            if collection.localizedTitle == title {
                found = collection
                stop.pointee = true
            }
        }
        return found
    }

    static func folder(titled title: String) -> PHCollectionList? {
        var found: PHCollectionList?
        PHCollectionList.fetchCollectionLists(with: .folder, subtype: .regularFolder, options: nil).enumerateObjects { list, _, stop in
            if list.localizedTitle == title {
                found = list
                stop.pointee = true
            }
        }
        return found
    }

    /// Identifiers of everything in `collection` (photos, videos, hidden), in the album's order.
    static func members(of collection: PHAssetCollection) -> [String] {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        var ids: [String] = []
        PHAsset.fetchAssets(in: collection, options: options).enumerateObjects { asset, _, _ in
            ids.append(asset.localIdentifier)
        }
        return ids
    }

    // MARK: Changing

    /// Arranges the library as described above and returns it. Fails with a clear message when
    /// Piq has no full access or the media hasn't been imported.
    static func prepare() async throws -> Layout {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw SetupError("Piq needs full Photos access: run PiqUITests/PhotoKitEndToEndTests/test00GrantFullAccess with TEST_RUNNER_PIQ_E2E=1 (`xcrun simctl privacy grant` doesn't give PhotoKit access on iOS 26.5)")
        }
        var items = items()
        guard items.filter({ !$0.isVideo }).count >= 40,
              items.contains(where: { $0.filename == tripVideoName }),
              items.contains(where: { $0.filename == emptyVideoName }) else {
            throw SetupError("The E2E media isn't in the library: run Tools/PhotoKitE2E/prepare-library.sh")
        }

        if album(titled: emptyTitle) == nil, let renamed = album(titled: emptyTitle + " (renamed)") {
            try await rename(albumID: renamed.localIdentifier, to: emptyTitle)
        }
        try await createMissingCollections()
        guard let trip = album(titled: tripTitle), let empty = album(titled: emptyTitle),
              let nested = album(titled: nestedTitle), let folder = folder(titled: folderTitle) else {
            throw SetupError("Couldn't create the E2E albums")
        }

        let photos = items.filter { !$0.isVideo && !$0.isHidden }
        let tripPhotos = Array(photos.filter { (1001...1050).contains($0.number) }.prefix(tripPhotoCount))
        let nestedPhotos = photos.filter { (1051...1055).contains($0.number) }
        guard tripPhotos.count == tripPhotoCount, nestedPhotos.count == 5,
              let tripVideo = items.first(where: { $0.filename == tripVideoName }),
              let emptyVideo = items.first(where: { $0.filename == emptyVideoName }) else {
            throw SetupError("Too few E2E photos are left (deleting tests use them up): import the media again with Tools/PhotoKitE2E/prepare-library.sh")
        }
        let favoriteNumbers = Set(stride(from: 1003, through: 1050, by: 3))
        let favorites = Array(photos.filter { favoriteNumbers.contains($0.number) }.prefix(favoritePhotoCount))

        let membership = MembershipPlan(
            wanted: [
                trip.localIdentifier: tripPhotos.map(\.id) + [tripVideo.id],
                empty.localIdentifier: [emptyVideo.id],
                nested.localIdentifier: nestedPhotos.map(\.id),
            ],
            current: [
                trip.localIdentifier: members(of: trip),
                empty.localIdentifier: members(of: empty),
                nested.localIdentifier: members(of: nested),
            ]
        )
        if !membership.isEmpty {
            try await PHPhotoLibrary.shared().performChanges { membership.apply() }
        }
        let favoriteIDs = Set(favorites.map(\.id) + [tripVideo.id])
        let flags = FavoritePlan(
            favorite: items.filter { favoriteIDs.contains($0.id) && !$0.isFavorite }.map(\.id),
            unfavorite: items.filter { !favoriteIDs.contains($0.id) && $0.isFavorite }.map(\.id)
        )
        if !flags.isEmpty {
            try await PHPhotoLibrary.shared().performChanges { flags.apply() }
        }
        // Capture dates as the files have them, in case a test that changes one was interrupted.
        let redated = photos.compactMap { photo in
            PhotoKitTestMedia.captureDate(of: photo.filename).flatMap { $0 == photo.creationDate ? nil : (photo.id, $0) }
        }
        for (id, date) in redated {
            try await setCreationDate(date, of: id)
        }
        if !membership.isEmpty || !flags.isEmpty || !redated.isEmpty {
            items = Self.items()
        }

        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        func refreshed(_ item: Item) -> Item { byID[item.id] ?? item }
        return Layout(
            trip: trip,
            empty: empty,
            nested: nested,
            folder: folder,
            tripPhotos: tripPhotos.map(refreshed),
            tripVideo: refreshed(tripVideo),
            emptyVideo: refreshed(emptyVideo),
            nestedPhotos: nestedPhotos.map(refreshed),
            favoritePhotos: favorites.map(refreshed)
        )
    }

    /// Creates the albums and the folder that don't exist yet, and puts "E2E Nested" in the folder.
    private static func createMissingCollections() async throws {
        let needsTrip = album(titled: tripTitle) == nil
        let needsEmpty = album(titled: emptyTitle) == nil
        let existingFolder = folder(titled: folderTitle)?.localIdentifier
        let existingNested = album(titled: nestedTitle)
        let nestedIsInFolder = existingNested.map { nested in
            PHCollectionList.fetchCollectionListsContaining(nested, options: nil).firstObject?.localizedTitle == folderTitle
        } ?? false
        let existingNestedID = existingNested?.localIdentifier
        guard needsTrip || needsEmpty || existingFolder == nil || !nestedIsInFolder else { return }

        let titles = (trip: tripTitle, empty: emptyTitle, folder: folderTitle, nested: nestedTitle)
        try await PHPhotoLibrary.shared().performChanges {
            if needsTrip { PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: titles.trip) }
            if needsEmpty { PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: titles.empty) }
            guard !nestedIsInFolder else { return }
            let folderRequest: PHCollectionListChangeRequest?
            if let existingFolder, let folder = PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [existingFolder], options: nil).firstObject {
                folderRequest = PHCollectionListChangeRequest(for: folder)
            } else {
                folderRequest = PHCollectionListChangeRequest.creationRequestForCollectionList(withTitle: titles.folder)
            }
            if let existingNestedID, let nested = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [existingNestedID], options: nil).firstObject {
                folderRequest?.addChildCollections([nested] as NSArray)
            } else {
                let nested = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: titles.nested)
                folderRequest?.addChildCollections([nested.placeholderForCreatedAssetCollection] as NSArray)
            }
        }
    }

    /// Sets (or clears) a photo's location: a change to a property Piq doesn't show, like the
    /// updates Photos makes in the background. Needs no confirmation.
    static func setLocation(_ coordinate: CLLocationCoordinate2D?, of assetID: String) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else { return }
            PHAssetChangeRequest(for: asset).location = coordinate.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
        }
    }

    /// Gives a photo a new capture date, as editing its date and time in Photos does.
    static func setCreationDate(_ date: Date, of assetID: String) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else { return }
            PHAssetChangeRequest(for: asset).creationDate = date
        }
    }

    static func rename(albumID: String, to title: String) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject else { return }
            PHAssetCollectionChangeRequest(for: album)?.title = title
        }
    }

    /// Removes `assetID` from the album or adds it back, the way another app (or Photos) would.
    static func setMembership(of assetID: String, in albumID: String, isMember: Bool) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject,
                  let request = PHAssetCollectionChangeRequest(for: album) else { return }
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
            if isMember {
                request.addAssets(assets)
            } else {
                request.removeAssets(assets)
            }
        }
    }
}

/// Album membership changes by identifier, so the change block captures nothing but strings.
private struct MembershipPlan: Sendable {
    /// Missing members by album, in the order to add them.
    var add: [String: [String]] = [:]
    var remove: [String: [String]] = [:]

    init(wanted: [String: [String]], current: [String: [String]]) {
        for (albumID, members) in wanted {
            let present = Set(current[albumID] ?? [])
            let missing = members.filter { !present.contains($0) }
            let extra = (current[albumID] ?? []).filter { !members.contains($0) }
            if !missing.isEmpty { add[albumID] = missing }
            if !extra.isEmpty { remove[albumID] = extra }
        }
    }

    var isEmpty: Bool { add.isEmpty && remove.isEmpty }

    /// Runs inside `performChanges`.
    func apply() {
        for (albumID, ids) in remove {
            guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject else { continue }
            PHAssetCollectionChangeRequest(for: album)?.removeAssets(PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil))
        }
        for (albumID, ids) in add {
            guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject else { continue }
            // One by one, so the album keeps the order of `ids`.
            let request = PHAssetCollectionChangeRequest(for: album)
            for id in ids {
                request?.addAssets(PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil))
            }
        }
    }
}

/// Favorite flags to change, by identifier.
private struct FavoritePlan: Sendable {
    let favorite: [String]
    let unfavorite: [String]

    var isEmpty: Bool { favorite.isEmpty && unfavorite.isEmpty }

    /// Runs inside `performChanges`.
    func apply() {
        PHAsset.fetchAssets(withLocalIdentifiers: favorite, options: nil).enumerateObjects { asset, _, _ in
            PHAssetChangeRequest(for: asset).isFavorite = true
        }
        PHAsset.fetchAssets(withLocalIdentifiers: unfavorite, options: nil).enumerateObjects { asset, _, _ in
            PHAssetChangeRequest(for: asset).isFavorite = false
        }
    }
}

/// What `Tools/PhotoKitE2E/gen_media.swift` wrote into each E2E photo, by filename, so tests can check PhotoKit's
/// answers against the source files. The formulas are the generator's.
enum PhotoKitTestMedia {
    /// Capture date of "E2E_1001.JPG" ... "E2E_1060.HEIC" and "E2E_SMALL.JPG", in local time
    /// (the EXIF dates carry no time zone, so Photos reads them in the simulator's).
    static func captureDate(of filename: String) -> Date? {
        let components: DateComponents
        if filename.hasPrefix("E2E_SMALL") {
            components = DateComponents(year: 2026, month: 10, day: 10, hour: 7, minute: 30, second: 0)
        } else if let number = Int(filename.dropFirst(4).prefix(4)), (1001...1060).contains(number) {
            let slot = ((number - 1001) * 37) % 60
            let minutes = 8 * 60 + (slot % 30) * 23
            components = DateComponents(year: 2026, month: 10, day: slot < 30 ? 10 : 11, hour: minutes / 60, minute: minutes % 60, second: (slot * 13) % 60)
        } else {
            return nil
        }
        return Calendar.current.date(from: components)
    }

    /// Pixel size of the source file.
    static func pixelSize(of filename: String) -> (width: Int, height: Int)? {
        if filename.hasPrefix("E2E_SMALL") { return (1200, 900) }
        guard let number = Int(filename.dropFirst(4).prefix(4)), (1001...1060).contains(number) else { return nil }
        let index = number - 1001
        if index == 9 { return (8064, 6048) }
        let (long, short) = index % 5 == 2 ? (3600, 2400) : (4032, 3024)
        return index % 3 == 1 ? (short, long) : (long, short)
    }
}
