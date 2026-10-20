import CoreLocation
@preconcurrency import Photos
import UIKit
import XCTest
@testable import Piq

/// `PhotoKitLibraryClient`, `PhotoKitImageSource` and an `AppModel` on top of them, against the
/// simulator's real photo library: the album list, photo order and details, deletion plans,
/// library changes (which ones reload, and how an open session follows them), and image sizes
/// and cancellation.
///
/// Gated: runs only with `TEST_RUNNER_PIQ_E2E=1`, on a prepared simulator.
/// `SIM=<udid> DD=<derived data dir> Tools/PhotoKitE2E/run-e2e.sh [all|unit|ui]` does every step
/// below, shell steps included, and exits non-zero when a test fails or skips; by hand:
///
/// 1. Media: `SIM=<udid> DD=<derived data dir> Tools/PhotoKitE2E/prepare-library.sh` generates 61
///    photos with EXIF capture dates and 2 videos (`Tools/PhotoKitE2E/gen_media.swift`, into
///    `$DD/media`), installs Piq, and imports whatever the library is missing with
///    `xcrun simctl addmedia` (photos earlier runs deleted come back as new copies).
/// 2. Full Photos access, by answering the real prompt (`xcrun simctl privacy grant photos` writes
///    a record PhotoKit ignores on iOS 26.5); the same UI test also hides E2E_1056 once:
///    `TEST_RUNNER_PIQ_E2E=1 xcodebuild test ... -only-testing:PiqUITests/PhotoKitEndToEndTests/test00GrantFullAccess`
/// 3. `TEST_RUNNER_PIQ_E2E=1 xcodebuild test ... -only-testing:PiqTests/PhotoKitIntegrationTests`.
///    Every test first arranges the albums and favorites with `PhotoKitTestLibrary.prepare()`
///    (idempotent; `test00PrepareLibrary` checks the result).
///
/// Nothing here deletes a photo (that always asks the person; the UI tests answer it).
@MainActor
final class PhotoKitIntegrationTests: XCTestCase {
    private var layout: PhotoKitTestLibrary.Layout!

    override func setUp() async throws {
        try XCTSkipUnless(PhotoKitTestLibrary.isEnabled, "Needs a prepared simulator and TEST_RUNNER_PIQ_E2E=1 (see the class comment)")
        layout = try await PhotoKitTestLibrary.prepare()
    }

    func test00PrepareLibrary() throws {
        XCTAssertEqual(layout.tripPhotos.count, PhotoKitTestLibrary.tripPhotoCount)
        XCTAssertEqual(Set(PhotoKitTestLibrary.members(of: layout.trip)), Set(layout.tripPhotos.map(\.id) + [layout.tripVideo.id]))
        XCTAssertEqual(PhotoKitTestLibrary.members(of: layout.empty), [layout.emptyVideo.id], "E2E Empty holds a video and no photos")
        XCTAssertEqual(Set(PhotoKitTestLibrary.members(of: layout.nested)), Set(layout.nestedPhotos.map(\.id)))
        // Hidden: PhotoKit no longer shows it to apps, even asked to include hidden photos.
        XCTAssertFalse(PhotoKitTestLibrary.items().contains { $0.filename == PhotoKitTestLibrary.hiddenPhotoName }, "E2E_1056 is hidden (PiqUITests/PhotoKitEndToEndTests/test00GrantFullAccess hides it)")
        let parent = PHCollectionList.fetchCollectionListsContaining(layout.nested, options: nil).firstObject
        XCTAssertEqual(parent?.localIdentifier, layout.folder.localIdentifier, "E2E Nested is inside E2E Folder")
        XCTAssertEqual(layout.favoritePhotos.count, PhotoKitTestLibrary.favoritePhotoCount)
        XCTAssertTrue(layout.favoritePhotos.allSatisfy(\.isFavorite))
        XCTAssertTrue(layout.tripVideo.isFavorite, "a favorite video, which Favorites must not count")
        XCTAssertTrue(layout.tripPhotos.contains { $0.filename.hasSuffix(".HEIC") })
        XCTAssertTrue(layout.tripPhotos.contains { $0.pixelWidth * $0.pixelHeight >= 48_000_000 }, "the 48 MP photo is in E2E Trip")
    }

    // MARK: Albums

    func testAlbumsAreRecentsAndFavoritesThenTheUserAlbumsInPhotosOrder() async throws {
        let albums = await PhotoKitLibraryClient().fetchAlbums()
        let recents = try XCTUnwrap(smartAlbum(.smartAlbumUserLibrary))
        let favorites = try XCTUnwrap(smartAlbum(.smartAlbumFavorites))
        guard albums.count >= 5 else { return XCTFail("Expected Recents, Favorites and the E2E albums, got \(albums.map(\.title))") }

        XCTAssertEqual(albums[0].id, recents.localIdentifier)
        XCTAssertEqual(albums[0].kind, .recents)
        XCTAssertEqual(albums[1].id, favorites.localIdentifier)
        XCTAssertEqual(albums[1].kind, .favorites)
        // The titles PhotoKit gives these albums in Piq's language, which is what Photos shows.
        XCTAssertEqual(albums[0].title, recents.localizedTitle)
        XCTAssertEqual(albums[0].title, "Recents")
        XCTAssertEqual(albums[1].title, "Favorites")
        XCTAssertTrue(albums.dropFirst(2).allSatisfy { $0.kind == .user })

        // Every regular album, in the order Photos lists them: the album inside E2E Folder takes
        // the folder's place.
        var expectedOrder: [String] = []
        PHCollectionList.fetchTopLevelUserCollections(with: nil).enumerateObjects { collection, _, _ in
            guard let title = collection.localizedTitle, title.hasPrefix("E2E ") else { return }
            expectedOrder.append(title == PhotoKitTestLibrary.folderTitle ? PhotoKitTestLibrary.nestedTitle : title)
        }
        XCTAssertEqual(albums.map(\.title).filter { $0.hasPrefix("E2E ") }, expectedOrder)
        var regular = Set<String>()
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil).enumerateObjects { album, _, _ in
            regular.insert(album.localIdentifier)
        }
        XCTAssertEqual(Set(albums.dropFirst(2).map(\.id)), regular, "no album is lost or listed twice")
        XCTAssertEqual(albums.count, Set(albums.map(\.id)).count)

        // Counts are photos only, covers the newest photo, checked against plain PhotoKit.
        for album in albums {
            let collection = try XCTUnwrap(PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [album.id], options: nil).firstObject)
            let photos = Self.photos(in: collection)
            XCTAssertEqual(album.photoCount, photos.count, "\(album.title) count")
            XCTAssertEqual(album.coverAssetID, photos.last?.localIdentifier, "\(album.title) cover")
        }

        let byTitle = Dictionary(albums.map { ($0.title, $0) }, uniquingKeysWith: { first, _ in first })
        let trip = try XCTUnwrap(byTitle[PhotoKitTestLibrary.tripTitle])
        XCTAssertEqual(trip.photoCount, 25, "26 items: 25 photos and a video")
        let newestTripPhoto = layout.tripPhotos.max { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
        XCTAssertEqual(trip.coverAssetID, newestTripPhoto?.id)
        let empty = try XCTUnwrap(byTitle[PhotoKitTestLibrary.emptyTitle])
        XCTAssertEqual(empty.photoCount, 0)
        XCTAssertNil(empty.coverAssetID, "a video is never the cover")
        XCTAssertEqual(byTitle[PhotoKitTestLibrary.nestedTitle]?.photoCount, 5)
        XCTAssertEqual(albums[1].photoCount, layout.favoritePhotos.count, "the favorite video isn't counted")
        let allPhotos = PHAsset.fetchAssets(with: .image, options: nil).count
        let e2ePhotos = PhotoKitTestLibrary.items().filter { !$0.isVideo && !$0.isHidden }.count
        XCTAssertEqual(albums[0].photoCount, allPhotos, "Recents has every photo")
        XCTAssertGreaterThanOrEqual(allPhotos, e2ePhotos + 6, "the E2E photos and the simulator's 6 samples")
    }

    // MARK: Photos

    func testAlbumPhotosComeOldestFirstWithoutVideos() async throws {
        let client = PhotoKitLibraryClient()
        let tripIDs = await client.assetIDs(inAlbum: layout.trip.localIdentifier)
        let ids = try XCTUnwrap(tripIDs)
        let byDate = layout.tripPhotos.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
        XCTAssertEqual(ids, byDate.map(\.id))
        XCTAssertNotEqual(ids, layout.tripPhotos.map(\.id), "capture order differs from filename order, the order they were added in")
        XCTAssertFalse(ids.contains(layout.tripVideo.id))
        let dates = byDate.compactMap(\.creationDate)
        XCTAssertEqual(dates.count, 25)
        XCTAssertTrue(zip(dates, dates.dropFirst()).allSatisfy { $0 < $1 }, "distinct capture dates, oldest first")

        let recents = try XCTUnwrap(smartAlbum(.smartAlbumUserLibrary))
        let recentIDs = await client.assetIDs(inAlbum: recents.localIdentifier)
        XCTAssertEqual(recentIDs, Self.photos(in: recents).map(\.localIdentifier))
        let emptyIDs = await client.assetIDs(inAlbum: layout.empty.localIdentifier)
        XCTAssertEqual(emptyIDs, [], "an album with only a video has no photos to sort")

        // An album that no longer exists (an identifier of the same shape that isn't there).
        let gone = await client.assetIDs(inAlbum: "0A1B2C3D-0000-4000-8000-000000000000/L0/040")
        XCTAssertNil(gone)
    }

    func testMetadataHasTheOriginalFilenameCaptureDateAndSize() async throws {
        let client = PhotoKitLibraryClient()
        let jpeg = try XCTUnwrap(layout.tripPhotos.first { $0.filename.hasSuffix(".JPG") })
        let heic = try XCTUnwrap(layout.tripPhotos.first { $0.filename.hasSuffix(".HEIC") })
        let large = try XCTUnwrap(layout.tripPhotos.first { $0.pixelWidth * $0.pixelHeight >= 48_000_000 })
        let portrait = try XCTUnwrap(layout.tripPhotos.first { $0.pixelHeight > $0.pixelWidth })
        let gone = "0A1B2C3D-0000-4000-8000-000000000001/L0/001"

        let metadata = await client.metadata(for: [jpeg.id, heic.id, large.id, portrait.id, gone])

        XCTAssertEqual(Set(metadata.keys), [jpeg.id, heic.id, large.id, portrait.id], "a photo that's gone is left out")
        for photo in [jpeg, heic, large, portrait] {
            let details = try XCTUnwrap(metadata[photo.id])
            // The library stores the files as IMG_00NN; the name shown is the original one.
            XCTAssertTrue(details.filename.hasPrefix("E2E_"), details.filename)
            XCTAssertEqual(details.filename, photo.filename)
            let date = try XCTUnwrap(PhotoKitTestMedia.captureDate(of: details.filename))
            XCTAssertEqual(details.creationDate, date, "\(details.filename): the EXIF capture date")
            let size = try XCTUnwrap(PhotoKitTestMedia.pixelSize(of: details.filename))
            XCTAssertEqual(details.pixelWidth, size.width, details.filename)
            XCTAssertEqual(details.pixelHeight, size.height, details.filename)
            XCTAssertEqual(details.chipText, "\(details.filename) · \(date.formatted(date: .omitted, time: .shortened))")
        }
        XCTAssertTrue(metadata[heic.id]?.filename.hasSuffix(".HEIC") == true)
        XCTAssertEqual(metadata[large.id].map { $0.pixelWidth * $0.pixelHeight }, 8064 * 6048)
        XCTAssertLessThan(try XCTUnwrap(metadata[portrait.id]?.aspectRatio), 1)

        // Asked again, the answer comes from the cache and is the same.
        let again = await client.metadata(for: [jpeg.id])
        XCTAssertEqual(again[jpeg.id], metadata[jpeg.id])
    }

    /// Review asks for the trash's details in one batch, some cached and some not. A library
    /// change that empties the cache while the others load must not make the cached photos look
    /// gone (left out of the answer, which the protocol reads as "not visible").
    func testALibraryChangeWhileDetailsLoadLeavesNoPhotoOut() async throws {
        let client = PhotoKitLibraryClient()
        let cached = layout.tripPhotos[0].id
        let uncached = Array(layout.tripPhotos.dropFirst().prefix(8).map(\.id))
        let first = await client.metadata(for: [cached])
        XCTAssertNotNil(first[cached])

        let batch = Task { await client.metadata(for: [cached] + uncached) }
        // The batch starts on the main actor and waits for PhotoKit; the change lands meanwhile,
        // as PhotoKit's notice of a relevant change would.
        await Task.yield()
        client.libraryChanged(LibraryWatch.Verdict(isRelevant: true, changedAssetIDs: [cached]))
        let details = await batch.value

        XCTAssertEqual(Set(details.keys), Set([cached] + uncached), "every photo is still there")
        XCTAssertEqual(details[cached], first[cached])
    }

    // MARK: Deleting

    func testTheDeletionPlanSeparatesDeletableAndMissingPhotos() throws {
        let present = layout.tripPhotos.prefix(3).map(\.id)
        let gone = "0A1B2C3D-0000-4000-8000-000000000002/L0/001"
        let plan = PhotoKitQueries.deletionPlan(for: present + [gone])
        XCTAssertEqual(Set(plan.deletable), Set(present))
        XCTAssertEqual(plan.missing, [gone])
        XCTAssertEqual(plan.undeletable, [])

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: layout.tripPhotos.map(\.id), options: nil)
        assets.enumerateObjects { asset, _, _ in
            XCTAssertTrue(asset.canPerform(.delete), "Photos lets Piq delete \(asset.localIdentifier)")
        }
        XCTAssertEqual(assets.count, layout.tripPhotos.count)
    }

    /// Photos that are already gone are reported as missing, not as a failure, and asking for
    /// nothing but those doesn't show the system prompt.
    func testDeletingPhotosThatAreAlreadyGoneReportsThemMissing() async throws {
        let gone = ["0A1B2C3D-0000-4000-8000-000000000003/L0/001", "0A1B2C3D-0000-4000-8000-000000000004/L0/001"]
        let report = try await PhotoKitLibraryClient().deleteAssets(gone)
        XCTAssertEqual(report, DeletionReport(deleted: [], missing: gone, undeletable: []))
    }

    // MARK: Library changes

    /// A photo leaves "E2E Trip" outside Piq (album membership changes need no prompt). The
    /// change reaches the app model once, after the debounce, and the open session drops the
    /// photo from its queue and its trash. Added back, it is queued again.
    ///
    /// PhotoKit reports a membership change twice, about 320 ms apart: the change itself, then
    /// the album's other photos and its derived data "changed". The second notice changes
    /// nothing Piq lists, so it must not cause a second reload.
    func testAPhotoLeavingTheAlbumLeavesTheOpenSessionAndComesBackWhenAddedAgain() async throws {
        let library = PhotoKitLibraryClient()
        let app = AppModel(library: library, images: PhotoKitImageSource(), container: PreviewSupport.inMemoryContainer())
        let reload = library.onChange
        let calls = CallLog()
        library.onChange = {
            calls.record()
            reload?()
        }
        let photoKit = ChangeRecorder()
        PHPhotoLibrary.shared().register(photoKit)
        defer { PHPhotoLibrary.shared().unregisterChangeObserver(photoKit) }

        await app.start()
        XCTAssertEqual(app.access, .authorized)
        let trip = try XCTUnwrap(app.albums.first { $0.id == layout.trip.localIdentifier })
        await app.openAlbum(trip)
        let session = try XCTUnwrap(app.activeSession)
        let ids = session.state.assetIDs
        XCTAssertEqual(ids.count, 25)
        session.sortNext([.keep, .delete, .delete, .keep])
        let leaving = ids[1]
        XCTAssertTrue(session.state.isMarked(leaving))
        addTeardownBlock { [albumID = layout.trip.localIdentifier] in
            try await PhotoKitTestLibrary.setMembership(of: leaving, in: albumID, isMember: true)
        }

        // Let anything still settling from the setup pass first.
        try await Task.sleep(for: .seconds(1))
        calls.reset()
        photoKit.reset()

        try await PhotoKitTestLibrary.setMembership(of: leaving, in: layout.trip.localIdentifier, isMember: false)

        await pollUntil("the open session drops the photo") { !session.state.assetIDs.contains(leaving) }
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertEqual(calls.count, 1, "one reload for the change")
        if let fired = calls.instants.first, let notice = photoKit.instants.first, notice < fired {
            let delay = fired - notice
            print("PhotoKit sent \(photoKit.instants.count) notices at \(photoKit.instants.map { $0 - notice }); onChange fired \(delay) after the first")
            XCTAssertGreaterThanOrEqual(delay, .milliseconds(300), "onChange waits for the debounce")
            XCTAssertLessThan(delay, .milliseconds(1_200))
        } else {
            XCTFail("PhotoKit reported the change (\(photoKit.instants.count) notices) before onChange fired")
        }
        XCTAssertFalse(session.state.isMarked(leaving), "gone from the trash")
        XCTAssertEqual(session.state.markedInOrder, [ids[2]])
        XCTAssertEqual(session.state.total, 24)
        XCTAssertEqual(session.state.sortedCount, 3)
        XCTAssertEqual(session.state.currentAssetID, ids[4], "the photo on screen stays")
        XCTAssertEqual(session.lastChange, .reconciled)
        XCTAssertEqual(app.albums.first { $0.id == trip.id }?.photoCount, 24)
        let record = try XCTUnwrap(app.store.session(albumID: trip.id))
        assertRecord(record, matches: session.state)

        // Back in the album: queued again in capture order, unsorted and not in the trash. It is
        // older than every unsorted photo, so it is next.
        calls.reset()
        try await PhotoKitTestLibrary.setMembership(of: leaving, in: layout.trip.localIdentifier, isMember: true)

        await pollUntil("the photo is queued again") { session.state.assetIDs.contains(leaving) }
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(session.state.total, 25)
        XCTAssertEqual(session.state.sortedCount, 3)
        XCTAssertFalse(session.state.isMarked(leaving))
        XCTAssertEqual(session.state.currentAssetID, leaving)
        XCTAssertEqual(Array(session.state.assetIDs.dropFirst(3)), [leaving] + ids.dropFirst(4))
        XCTAssertEqual(app.albums.first { $0.id == trip.id }?.photoCount, 25)
    }

    /// Photos reports property updates all the time (analysis, iCloud, a new location). They
    /// change nothing Piq lists, so they must not reload albums and sessions mid-sort.
    func testAChangeToAPropertyPiqDoesNotShowDoesNotReload() async throws {
        let library = PhotoKitLibraryClient()
        _ = await library.fetchAlbums()
        let calls = CallLog()
        library.onChange = { calls.record() }
        let photoKit = ChangeRecorder()
        PHPhotoLibrary.shared().register(photoKit)
        defer { PHPhotoLibrary.shared().unregisterChangeObserver(photoKit) }
        let photo = layout.tripPhotos[5].id
        addTeardownBlock { try await PhotoKitTestLibrary.setLocation(nil, of: photo) }
        try await Task.sleep(for: .seconds(1))
        calls.reset()
        photoKit.reset()

        try await PhotoKitTestLibrary.setLocation(CLLocationCoordinate2D(latitude: 64.1466, longitude: -21.9426), of: photo)

        try await Task.sleep(for: .seconds(1.5))
        XCTAssertGreaterThan(photoKit.instants.count, 0, "PhotoKit reported the change")
        XCTAssertEqual(calls.count, 0, "nothing Piq lists changed")
    }

    /// A new capture date moves a photo in its album: Piq reloads, the open session's unsorted
    /// queue follows the new order (the photo on screen stays), and the photo's details are read
    /// again rather than served from the cache.
    func testANewCaptureDateReordersTheQueueAndRefreshesTheDetails() async throws {
        let library = PhotoKitLibraryClient()
        let app = AppModel(library: library, images: PhotoKitImageSource(), container: PreviewSupport.inMemoryContainer())
        await app.start()
        let trip = try XCTUnwrap(app.albums.first { $0.id == layout.trip.localIdentifier })
        await app.openAlbum(trip)
        let session = try XCTUnwrap(app.activeSession)
        session.sortNext([.keep, .keep])
        let ids = session.state.assetIDs
        let moving = ids[10]
        let before = await library.metadata(for: [moving, ids[2]])
        let original = try XCTUnwrap(before[moving]?.creationDate)
        let onScreenDate = try XCTUnwrap(before[ids[2]]?.creationDate)
        addTeardownBlock { try await PhotoKitTestLibrary.setCreationDate(original, of: moving) }

        // Just after the photo on screen: it becomes the next one.
        let newDate = onScreenDate.addingTimeInterval(1)
        try await PhotoKitTestLibrary.setCreationDate(newDate, of: moving)

        await pollUntil("the queue follows the new capture order") { session.state.assetIDs[3] == moving }
        XCTAssertEqual(session.state.currentAssetID, ids[2], "the photo on screen stays")
        XCTAssertEqual(Array(session.state.assetIDs.prefix(2)), Array(ids.prefix(2)), "sorted photos keep their order")
        XCTAssertEqual(session.state.total, ids.count)
        let after = await library.metadata(for: [moving])
        XCTAssertEqual(after[moving]?.creationDate, newDate, "fresh details, not the cached ones")
    }

    /// A photo without a capture date: PhotoKit sorts it first ("oldest"), and its chip shows the
    /// filename alone.
    func testAPhotoWithoutACaptureDate() async throws {
        let photo = try XCTUnwrap(layout.tripPhotos.last)
        let original = try XCTUnwrap(photo.creationDate)
        addTeardownBlock { try await PhotoKitTestLibrary.setCreationDate(original, of: photo.id) }
        try await PHPhotoLibrary.shared().performChanges {
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [photo.id], options: nil).firstObject else { return }
            PHAssetChangeRequest(for: asset).creationDate = nil
        }
        let stored = PHAsset.fetchAssets(withLocalIdentifiers: [photo.id], options: nil).firstObject?.creationDate
        print("Creation date after setting nil: \(String(describing: stored))")
        try XCTSkipIf(stored != nil, "PhotoKit keeps a capture date (\(String(describing: stored))): a photo can't lose it")

        let client = PhotoKitLibraryClient()
        let ids = await client.assetIDs(inAlbum: layout.trip.localIdentifier)
        XCTAssertEqual(ids?.first, photo.id, "no date sorts first")
        let metadata = await client.metadata(for: [photo.id])
        XCTAssertNil(metadata[photo.id]?.creationDate)
        XCTAssertEqual(metadata[photo.id]?.chipText, photo.filename)
    }

    /// Renaming an album reloads the list with the new title.
    func testRenamingAnAlbumReloadsTheList() async throws {
        let library = PhotoKitLibraryClient()
        let app = AppModel(library: library, images: PhotoKitImageSource(), container: PreviewSupport.inMemoryContainer())
        await app.start()
        let albumID = layout.empty.localIdentifier
        let renamed = PhotoKitTestLibrary.emptyTitle + " (renamed)"
        addTeardownBlock { try await PhotoKitTestLibrary.rename(albumID: albumID, to: PhotoKitTestLibrary.emptyTitle) }

        try await PhotoKitTestLibrary.rename(albumID: albumID, to: renamed)

        await pollUntil("the album list has the new title") { app.albums.first { $0.id == albumID }?.title == renamed }
    }

    // MARK: Images

    func testImagesComeAtTheSizesTheScreensNeed() async throws {
        let images = PhotoKitImageSource()
        let landscape = try XCTUnwrap(layout.tripPhotos.first { $0.pixelWidth == 4032 && $0.pixelHeight == 3024 })
        let portrait = try XCTUnwrap(layout.tripPhotos.first { $0.pixelWidth == 3024 && $0.pixelHeight == 4032 })
        let large = try XCTUnwrap(layout.tripPhotos.first { $0.pixelWidth == 8064 })
        let small = try XCTUnwrap(PhotoKitTestLibrary.items().first { $0.filename == "E2E_SMALL.JPG" }, "run Tools/PhotoKitE2E/prepare-library.sh")

        // A 246 x 172 pt album cover at 2x, aspect-filled.
        let thumbnail = await images.thumbnail(for: landscape.id, pointSize: CGSize(width: 246, height: 172), scale: 2)
        let coverSize = Self.pixelSize(of: try XCTUnwrap(thumbnail))
        XCTAssertGreaterThanOrEqual(coverSize.height, 344 - 1, "fills the cover's height: \(coverSize)")
        XCTAssertGreaterThanOrEqual(coverSize.width, 492 - 1, "fills the cover's width: \(coverSize)")
        XCTAssertLessThanOrEqual(max(coverSize.width, coverSize.height), 1_024, "not much bigger than asked: \(coverSize)")

        let preview = await images.preview(for: landscape.id)
        XCTAssertNotNil(preview, "a preview for \(landscape.filename)")
        if let preview {
            let previewSize = Self.pixelSize(of: preview)
            XCTAssertLessThanOrEqual(max(previewSize.width, previewSize.height), 1_024, "a quick, small preview: \(previewSize)")
            XCTAssertEqual(previewSize.width / previewSize.height, 4.0 / 3.0, accuracy: 0.05)
        }

        // Full resolution: the screen's native long edge (at least 2048), never upscaled.
        let screen = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first)
        let edge = max(screen.nativeBounds.width, screen.nativeBounds.height, 2048)
        print("Full image edge: \(edge) px (screen native \(screen.nativeBounds.size))")
        for (photo, expected) in [
            (landscape, CGSize(width: edge, height: edge * 3 / 4)),
            (portrait, CGSize(width: edge * 3 / 4, height: edge)),
            (large, CGSize(width: edge, height: edge * 3 / 4)),
            (small, CGSize(width: 1200, height: 900)),
        ] {
            let image = await images.fullImage(for: photo.id) { _ in }
            let size = Self.pixelSize(of: try XCTUnwrap(image, photo.filename))
            XCTAssertEqual(size.width, expected.width, accuracy: 1, "\(photo.filename): \(size)")
            XCTAssertEqual(size.height, expected.height, accuracy: 1, "\(photo.filename): \(size)")
        }
        let gone = await images.fullImage(for: "0A1B2C3D-0000-4000-8000-000000000005/L0/001") { _ in }
        XCTAssertNil(gone)
    }

    /// Cancelling the task that waits for an image returns nil at once and leaves no request
    /// waiting forever (a leaked continuation would never let the task finish), whether the
    /// cancel comes before PhotoKit starts or while it decodes a 48 MP original.
    func testCancellingAnImageRequestReturnsNilPromptly() async throws {
        let images = PhotoKitImageSource()
        let photos = [try XCTUnwrap(layout.tripPhotos.first { $0.pixelWidth == 8064 })] + layout.tripPhotos.prefix(8)
        for (index, photo) in photos.enumerated() {
            let box = ImageBox()
            let task = Task {
                box.image = await images.fullImage(for: photo.id) { _ in }
                box.isFinished = true
            }
            if index % 2 == 1 {
                try await Task.sleep(for: .milliseconds(5))
            }
            let cancelled = ContinuousClock.now
            task.cancel()
            await pollUntil("the request for \(photo.filename) ends after the cancel", timeout: .seconds(2)) { box.isFinished }
            let elapsed = ContinuousClock.now - cancelled
            XCTAssertNil(box.image, "\(photo.filename): a cancelled request has no image")
            XCTAssertLessThan(elapsed, .milliseconds(300), "\(photo.filename): ended \(elapsed) after the cancel")
        }
        // The source still works afterwards.
        let image = await images.fullImage(for: photos[1].id) { _ in }
        XCTAssertNotNil(image)
    }

    // MARK: Access

    func testRequestingAccessAgainAnswersAtOnceWithoutAPrompt() async {
        let client = PhotoKitLibraryClient()
        XCTAssertEqual(client.access, .authorized)
        let answer = await client.requestAccess()
        XCTAssertEqual(answer, .authorized)
    }

    // MARK: Helpers

    private func smartAlbum(_ subtype: PHAssetCollectionSubtype) -> PHAssetCollection? {
        PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil).firstObject
    }

    /// The album's photos by plain PhotoKit: every asset, filtered here to photos from the
    /// person's library, oldest first.
    private static func photos(in collection: PHAssetCollection) -> [PHAsset] {
        var photos: [PHAsset] = []
        PHAsset.fetchAssets(in: collection, options: nil).enumerateObjects { asset, _, _ in
            if asset.mediaType == .image, asset.sourceType == .typeUserLibrary { photos.append(asset) }
        }
        return photos.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
    }

    private static func pixelSize(of image: UIImage) -> CGSize {
        guard let cgImage = image.cgImage else { return CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale) }
        return CGSize(width: cgImage.width, height: cgImage.height)
    }
}

/// When `onChange` fired.
@MainActor
private final class CallLog {
    private(set) var instants: [ContinuousClock.Instant] = []
    var count: Int { instants.count }
    func record() { instants.append(.now) }
    func reset() { instants = [] }
}

/// When PhotoKit reported library changes (on its own queue).
private final class ChangeRecorder: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ContinuousClock.Instant] = []

    var instants: [ContinuousClock.Instant] { lock.withLock { recorded } }

    func reset() { lock.withLock { recorded = [] } }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        lock.withLock { recorded.append(.now) }
    }
}

@MainActor
private final class ImageBox {
    var image: UIImage?
    var isFinished = false
}
