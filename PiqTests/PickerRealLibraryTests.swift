@preconcurrency import Photos
import XCTest
@testable import Piq

/// The picker's "Date created" order on the simulator's real photo library.
///
/// PhotoKit has no public creation date for an album: on iPadOS 26.5 `PHAssetCollection` has no
/// such property, `creationDate` in a collection fetch's sort descriptors or predicate raises
/// "Unsupported sort descriptor/predicate in fetch options", and `startDate`/`endDate` are the
/// capture range of the album's photos, which Photos fills in later (nil for an album made a
/// moment ago, even with a photo in it). What PhotoKit does give is the order of a regular-album
/// fetch with no sort descriptor, which follows when the albums were made; Piq ranks albums by it
/// (`AlbumSummary.creationRank`). Apple doesn't document that order, so this test pins it down on
/// albums made in a known order whose titles, photos, renames and place in their folder all
/// suggest other orders.
///
/// Gated: runs only with `TEST_RUNNER_PIQ_E2E=1`, on a simulator prepared for the PhotoKit
/// end-to-end tests (`Tools/PhotoKitE2E/run-e2e.sh`, see `PhotoKitIntegrationTests`): it needs full
/// Photos access and the E2E photos. The first run makes a folder, "Picker Made Folder", and in
/// it three albums, one after the other, a second apart; later runs reuse them (nothing here
/// deletes anything, and the E2E albums aren't touched):
///
/// 1. "Picker Made Zeta", made first under a temporary title and renamed once the others exist;
///    it holds the three latest-captured E2E photos.
/// 2. "Picker Made Alpha", made second; no photos.
/// 3. "Picker Made Mu", made last; the three earliest-captured E2E photos. It is then moved to
///    the top of the folder.
///
/// Photos order (the folder's): Mu, Zeta, Alpha. By title: Alpha, Mu, Zeta. By newest photo:
/// Zeta, Mu, Alpha. "Date created", the album made last first: Mu, Alpha, Zeta. Every run also
/// takes a photo out of Zeta and puts it back, so a change to the oldest album is checked to
/// leave it where it is.
@MainActor
final class PickerRealLibraryTests: XCTestCase {
    static let folderTitle = "Picker Made Folder"
    /// In the order they are made.
    static let titles = ["Picker Made Zeta", "Picker Made Alpha", "Picker Made Mu"]
    /// The first album's title until the others exist.
    static let provisionalTitle = "Picker Made (renamed later)"
    /// Fixture albums from a run that didn't finish are renamed to this and left alone.
    static let retiredTitle = "Picker Made (retired)"

    override func setUp() async throws {
        try XCTSkipUnless(PhotoKitTestLibrary.isEnabled, "Needs a prepared simulator and TEST_RUNNER_PIQ_E2E=1 (see the class comment)")
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw PhotoKitTestLibrary.SetupError("Piq needs full Photos access (see PhotoKitIntegrationTests)")
        }
        try await arrangeAlbums()
    }

    func testDateCreatedListsTheAlbumMadeLastFirst() async throws {
        let albums = await PhotoKitLibraryClient().fetchAlbums()
        let byDate = AlbumBrowsing.sorted(albums, by: .dateCreated)
        print("Picker order, Photos: \(albums.map(\.title))")
        print("Picker order, date created: \(byDate.map { "\($0.title) [\($0.creationRank.map(String.init) ?? "no rank")]" })")

        // Every listed album of the person's has its place in PhotoKit's unsorted regular-album
        // fetch; Recents and Favorites have none.
        var fetchOrder: [String: Int] = [:]
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil).enumerateObjects { album, index, _ in
            fetchOrder[album.localIdentifier] = index
        }
        for album in albums {
            XCTAssertEqual(album.creationRank, album.kind == .user ? fetchOrder[album.id] : nil, "\(album.title)")
        }

        // Recents and Favorites first, then the person's albums, the one made last first.
        XCTAssertEqual(byDate.prefix(2).map(\.kind), [.recents, .favorites])
        let ranks = byDate.dropFirst(2).map(\.creationRank)
        XCTAssertTrue(ranks.allSatisfy { $0 != nil }, "every album of the person's is ranked")
        let known = ranks.compactMap { $0 }
        XCTAssertTrue(zip(known, known.dropFirst()).allSatisfy { $0 > $1 }, "the album made last first")

        // The albums made for this test, against the orders they could be mistaken for.
        let made = Self.titles
        XCTAssertEqual(byDate.map(\.title).filter(made.contains), ["Picker Made Mu", "Picker Made Alpha", "Picker Made Zeta"], "Date created: made last first")
        XCTAssertEqual(albums.map(\.title).filter(made.contains), ["Picker Made Mu", "Picker Made Zeta", "Picker Made Alpha"], "Photos order is the folder's")
        let byNewestPhoto = albums.filter { made.contains($0.title) }
            .sorted { ($0.newestPhotoDate ?? .distantPast) > ($1.newestPhotoDate ?? .distantPast) }
        XCTAssertEqual(byNewestPhoto.map(\.title), ["Picker Made Zeta", "Picker Made Mu", "Picker Made Alpha"], "the photos suggest another order")

        // The newest photo, still read for albums without a rank: the album's own newest photo,
        // read from PhotoKit (the E2E runs delete and re-import photos, so an album made earlier
        // may no longer hold the library's newest or oldest ones).
        let summaries = Dictionary(albums.map { ($0.title, $0) }, uniquingKeysWith: { first, _ in first })
        for title in made {
            let summary = try XCTUnwrap(summaries[title], title)
            XCTAssertEqual(summary.newestPhotoDate, Self.newestPhotoDate(inAlbum: summary.id), title)
        }
        XCTAssertNotNil(summaries["Picker Made Zeta"]?.newestPhotoDate)
        XCTAssertNotNil(summaries["Picker Made Mu"]?.newestPhotoDate)
        XCTAssertNil(summaries["Picker Made Alpha"]?.newestPhotoDate)
    }

    // MARK: Arranging

    /// The capture date of the newest photo in an album, straight from PhotoKit.
    private static func newestPhotoDate(inAlbum albumID: String) -> Date? {
        guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject else {
            return nil
        }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 1
        return PHAsset.fetchAssets(in: album, options: options).firstObject?.creationDate
    }

    /// The E2E photos (not videos, not hidden), oldest first.
    private static func photos() -> [PhotoKitTestLibrary.Item] {
        PhotoKitTestLibrary.items()
            .filter { !$0.isVideo && !$0.isHidden && $0.creationDate != nil }
            .sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
    }

    /// Makes the folder and its albums if they aren't all there, then takes a photo out of the
    /// oldest album and puts it back.
    private func arrangeAlbums() async throws {
        let photos = Self.photos()
        guard photos.count >= 6 else {
            throw PhotoKitTestLibrary.SetupError("The E2E media isn't in the library: run Tools/PhotoKitE2E/prepare-library.sh")
        }
        let isComplete = PhotoKitTestLibrary.folder(titled: Self.folderTitle) != nil
            && Self.titles.allSatisfy { PhotoKitTestLibrary.album(titled: $0) != nil }
        if !isComplete {
            try await retireLeftovers()
            try await makeAlbums(newest: photos.suffix(3).map(\.id), oldest: photos.prefix(3).map(\.id))
        }
        let zeta = try XCTUnwrap(PhotoKitTestLibrary.album(titled: Self.titles[0]))
        let newest = try XCTUnwrap(photos.last?.id)
        try await PhotoKitTestLibrary.setMembership(of: newest, in: zeta.localIdentifier, isMember: false)
        try await PhotoKitTestLibrary.setMembership(of: newest, in: zeta.localIdentifier, isMember: true)
    }

    /// Renames what an unfinished run left, so the albums made next are the only ones with
    /// these titles.
    private func retireLeftovers() async throws {
        for title in Self.titles + [Self.provisionalTitle] {
            for _ in 0..<10 {
                guard let album = PhotoKitTestLibrary.album(titled: title) else { break }
                try await PhotoKitTestLibrary.rename(albumID: album.localIdentifier, to: Self.retiredTitle)
            }
        }
        if let folder = PhotoKitTestLibrary.folder(titled: Self.folderTitle) {
            let folderID = folder.localIdentifier
            let retired = Self.retiredTitle
            try await PHPhotoLibrary.shared().performChanges {
                guard let folder = PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [folderID], options: nil).firstObject else { return }
                PHCollectionListChangeRequest(for: folder)?.title = retired
            }
        }
    }

    /// Makes the folder, then the three albums in it one at a time, renames the first, gives
    /// them their photos and moves the last made to the top of the folder.
    private func makeAlbums(newest: [String], oldest: [String]) async throws {
        let folderTitle = Self.folderTitle
        try await PHPhotoLibrary.shared().performChanges {
            PHCollectionListChangeRequest.creationRequestForCollectionList(withTitle: folderTitle)
        }
        let folderID = try XCTUnwrap(PhotoKitTestLibrary.folder(titled: folderTitle)).localIdentifier
        let contents = [(Self.provisionalTitle, newest), (Self.titles[1], []), (Self.titles[2], oldest)]
        for (title, photoIDs) in contents {
            try await PHPhotoLibrary.shared().performChanges {
                let album = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
                if !photoIDs.isEmpty {
                    album.addAssets(PHAsset.fetchAssets(withLocalIdentifiers: photoIDs, options: nil))
                }
                guard let folder = PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [folderID], options: nil).firstObject else { return }
                PHCollectionListChangeRequest(for: folder)?.addChildCollections([album.placeholderForCreatedAssetCollection] as NSArray)
            }
            // Made at distinct moments, in order.
            try await Task.sleep(for: .seconds(1))
        }
        let first = try XCTUnwrap(PhotoKitTestLibrary.album(titled: Self.provisionalTitle))
        try await PhotoKitTestLibrary.rename(albumID: first.localIdentifier, to: Self.titles[0])
        try await PHPhotoLibrary.shared().performChanges {
            guard let folder = PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [folderID], options: nil).firstObject else { return }
            let children = PHCollection.fetchCollections(in: folder, options: nil)
            PHCollectionListChangeRequest(for: folder, childCollections: children)?.moveChildCollections(at: IndexSet(integer: 2), to: 0)
        }
    }
}
