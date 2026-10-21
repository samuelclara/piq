import SwiftUI
import XCTest
@testable import Piq

/// The album picker's search (by title, ignoring case and diacritics, Recents and Favorites
/// included) and its two orders (Photos order; date created, the album made last first, with
/// Recents and Favorites pinned), on hand-made albums and on the mock library.
@MainActor
final class PickerBrowsingTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private lazy var recents = album("recents", "Recents", .recents, made: nil, daysAgo: 0)
    private lazy var favorites = album("favorites", "Favorites", .favorites, made: nil, daysAgo: 3)
    // Made in this order: Drafts, Iceland, Lisbon, Café, Scans. Their photos say otherwise.
    private lazy var iceland = album("iceland", "Iceland 2026", made: 1, daysAgo: 30)
    private lazy var cafe = album("cafe", "Café Society", made: 3, daysAgo: 2)
    private lazy var empty = album("empty", "Drafts", made: 0, daysAgo: nil)
    private lazy var lisbon = album("lisbon", "Weekend in Lisbon", made: 2, daysAgo: 10)
    private lazy var alsoEmpty = album("also-empty", "Scans", made: 4, daysAgo: nil)
    /// As Photos lists them.
    private var photosOrder: [AlbumSummary] { [recents, favorites, iceland, cafe, empty, lisbon, alsoEmpty] }

    // MARK: Search

    func testAnEmptyOrBlankQueryShowsEveryAlbumInOrder() {
        XCTAssertEqual(titles(AlbumBrowsing.visibleAlbums(photosOrder, matching: "", order: .photos)), titles(photosOrder))
        XCTAssertEqual(titles(AlbumBrowsing.visibleAlbums(photosOrder, matching: "   ", order: .photos)), titles(photosOrder))
    }

    func testMatchingIgnoresCaseDiacriticsAndSurroundingSpaces() {
        XCTAssertEqual(visible("ice"), ["Iceland 2026"])
        XCTAssertEqual(visible("ICELAND"), ["Iceland 2026"])
        XCTAssertEqual(visible("cafe"), ["Café Society"])
        XCTAssertEqual(visible("CAFÉ"), ["Café Society"])
        XCTAssertEqual(visible("  lisbon "), ["Weekend in Lisbon"])
        XCTAssertEqual(visible("2026"), ["Iceland 2026"])
        XCTAssertEqual(visible("in lis"), ["Weekend in Lisbon"], "a phrase matches as typed")
        XCTAssertEqual(visible("Kyoto"), [])
    }

    func testRecentsAndFavoritesAreSearchedToo() {
        XCTAssertEqual(visible("rec"), ["Recents"])
        XCTAssertEqual(visible("fav"), ["Favorites"])
        XCTAssertEqual(visible("s"), ["Recents", "Favorites", "Café Society", "Drafts", "Weekend in Lisbon", "Scans"], "every title with an s, in Photos order")
    }

    /// The field keeps one line: tabs (which Tab would type) go, pasted line breaks become spaces.
    func testTheSearchFieldKeepsOneLine() {
        XCTAssertEqual(SearchField.singleLine("Iceland"), "Iceland")
        XCTAssertEqual(SearchField.singleLine("\t\tIce\tland"), "Iceland")
        XCTAssertEqual(SearchField.singleLine("Weekend\nin\r\nLisbon"), "Weekend in Lisbon")
        XCTAssertEqual(SearchField.singleLine(""), "")
    }

    func testANormalizedQueryIsTheTrimmedText() {
        XCTAssertEqual(AlbumBrowsing.normalizedQuery("  Lisbon \n"), "Lisbon")
        XCTAssertEqual(AlbumBrowsing.normalizedQuery(""), "")
    }

    // MARK: Order

    func testPhotosOrderIsTheListAsGiven() {
        XCTAssertEqual(titles(AlbumBrowsing.sorted(photosOrder, by: .photos)), titles(photosOrder))
    }

    /// The album made last comes first, whatever its photos: an empty album made today goes
    /// before an older one holding the newest photos.
    func testDateCreatedPinsRecentsAndFavoritesThenTheAlbumMadeLastFirst() {
        XCTAssertEqual(
            titles(AlbumBrowsing.sorted(photosOrder, by: .dateCreated)),
            ["Recents", "Favorites", "Scans", "Café Society", "Weekend in Lisbon", "Iceland 2026", "Drafts"]
        )
    }

    /// An album without a place in the creation order (one made between two listings, or built
    /// elsewhere in the code) follows the ranked ones, by its newest photo; with neither, last.
    func testAlbumsWithoutACreationRankFollowByTheirNewestPhoto() {
        let now = Date()
        let ranked = AlbumSummary(id: "r", title: "Ranked, old photos", kind: .user, photoCount: 1, coverAssetID: "r", creationRank: 0, newestPhotoDate: now.addingTimeInterval(-86_400))
        let newPhotos = AlbumSummary(id: "n", title: "Unranked, new photos", kind: .user, photoCount: 1, coverAssetID: "n", newestPhotoDate: now)
        let oldPhotos = AlbumSummary(id: "o", title: "Unranked, old photos", kind: .user, photoCount: 1, coverAssetID: "o", newestPhotoDate: now.addingTimeInterval(-60))
        let nothing = AlbumSummary(id: "x", title: "Unranked, empty", kind: .user, photoCount: 0, coverAssetID: nil)
        XCTAssertEqual(
            titles(AlbumBrowsing.sorted([nothing, oldPhotos, ranked, newPhotos], by: .dateCreated)),
            ["Ranked, old photos", "Unranked, new photos", "Unranked, old photos", "Unranked, empty"]
        )
    }

    /// Recents and Favorites stay first even when a user album is newer, and albums that tie keep
    /// Photos' order.
    func testPinnedAlbumsStayFirstAndTiesKeepPhotosOrder() {
        let now = Date()
        let newer = AlbumSummary(id: "new", title: "Newer than Recents", kind: .user, photoCount: 1, coverAssetID: "n", newestPhotoDate: now.addingTimeInterval(60))
        let twinA = AlbumSummary(id: "a", title: "Twin A", kind: .user, photoCount: 1, coverAssetID: "a", newestPhotoDate: now)
        let twinB = AlbumSummary(id: "b", title: "Twin B", kind: .user, photoCount: 1, coverAssetID: "b", newestPhotoDate: now)
        let albums = [twinB, recents, newer, twinA, favorites]
        XCTAssertEqual(titles(AlbumBrowsing.sorted(albums, by: .dateCreated)), ["Recents", "Favorites", "Newer than Recents", "Twin B", "Twin A"])
        XCTAssertEqual(titles(AlbumBrowsing.sorted(albums, by: .photos)), ["Recents", "Favorites", "Twin B", "Newer than Recents", "Twin A"])
    }

    func testSortingAndSearchingTogether() {
        XCTAssertEqual(
            titles(AlbumBrowsing.visibleAlbums(photosOrder, matching: "s", order: .dateCreated)),
            ["Recents", "Favorites", "Scans", "Café Society", "Weekend in Lisbon", "Drafts"]
        )
        XCTAssertEqual(titles(AlbumBrowsing.visibleAlbums(photosOrder, matching: "e", order: .dateCreated)), ["Recents", "Favorites", "Café Society", "Weekend in Lisbon", "Iceland 2026"])
    }

    /// The Sort control shows only when there are albums of the person's to order; under limited
    /// access Piq lists Recents and Favorites only, which never move.
    func testTheSortControlShowsOnlyWithAlbumsToOrder() {
        XCTAssertTrue(AlbumBrowsing.offersSort(photosOrder, access: .authorized, hasLoaded: true))
        XCTAssertFalse(AlbumBrowsing.offersSort([recents, favorites], access: .authorized, hasLoaded: true))
        XCTAssertTrue(AlbumBrowsing.offersSort([], access: .authorized, hasLoaded: false), "shown while the albums load, so the header keeps still")
        XCTAssertFalse(AlbumBrowsing.offersSort([recents, favorites], access: .limited, hasLoaded: true))
        XCTAssertFalse(AlbumBrowsing.offersSort([], access: .limited, hasLoaded: false))
    }

    // MARK: The choice

    func testTheOrdersTitlesAndStoredValues() {
        XCTAssertEqual(AlbumSortOrder.allCases, [.photos, .dateCreated])
        XCTAssertEqual(AlbumSortOrder.photos.title, "Photos order")
        XCTAssertEqual(AlbumSortOrder.dateCreated.title, "Date created")
        // Stored in user defaults under these values: changing them would forget people's choice.
        XCTAssertEqual(AlbumSortOrder.photos.rawValue, "photos")
        XCTAssertEqual(AlbumSortOrder.dateCreated.rawValue, "dateCreated")
        XCTAssertEqual(AlbumSortOrder.storageKey, "PiqAlbumSortOrder")
    }

    /// The choice round-trips through user defaults the way `@AppStorage` keeps it; an unknown
    /// stored value falls back to Photos order.
    func testTheChoiceIsKeptInUserDefaults() throws {
        let suite = "PickerBrowsingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = AppStorage(wrappedValue: AlbumSortOrder.photos, AlbumSortOrder.storageKey, store: defaults)
        XCTAssertEqual(first.wrappedValue, .photos, "Photos order by default")
        first.wrappedValue = .dateCreated
        XCTAssertEqual(defaults.string(forKey: AlbumSortOrder.storageKey), "dateCreated")
        let relaunched = AppStorage(wrappedValue: AlbumSortOrder.photos, AlbumSortOrder.storageKey, store: defaults)
        XCTAssertEqual(relaunched.wrappedValue, .dateCreated)

        defaults.set("newestFirst", forKey: AlbumSortOrder.storageKey)
        XCTAssertEqual(AppStorage(wrappedValue: AlbumSortOrder.photos, AlbumSortOrder.storageKey, store: defaults).wrappedValue, .photos)
    }

    // MARK: Library dates

    /// Albums made elsewhere in the code without a creation rank or a date have neither.
    func testAnAlbumHasNoCreationRankOrDateUnlessGivenOne() {
        let plain = AlbumSummary(id: "x", title: "X", kind: .user, photoCount: 2, coverAssetID: "x2")
        XCTAssertNil(plain.creationRank)
        XCTAssertNil(plain.newestPhotoDate)
    }

    /// The mock library's albums were made in an order that is neither Photos' order nor the
    /// order of their newest photos, so "Date created" visibly differs from both.
    func testTheMockLibrarysAlbumsHaveTheirOwnCreationOrder() async throws {
        let library = MockPhotoLibrary()
        let albums = await library.fetchAlbums()
        XCTAssertEqual(titles(albums), ["Recents", "Favorites", "Iceland 2026", "Weekend in Lisbon", "Family", "Drafts"])
        XCTAssertEqual(
            titles(AlbumBrowsing.sorted(albums, by: .dateCreated)),
            ["Recents", "Favorites", "Drafts", "Weekend in Lisbon", "Iceland 2026", "Family"]
        )
        XCTAssertEqual(albums.filter { $0.kind != .user }.compactMap(\.creationRank), [], "Recents and Favorites have no rank")
        let ranks = albums.filter { $0.kind == .user }.compactMap(\.creationRank)
        XCTAssertEqual(ranks.count, 4)
        XCTAssertEqual(Set(ranks).count, ranks.count, "distinct ranks")
        for album in albums {
            let ids = library.photoIDs(inAlbum: album.id)
            let dates = await library.metadata(for: ids).values.compactMap(\.creationDate)
            XCTAssertEqual(album.newestPhotoDate, dates.max(), "\(album.title)'s newest photo")
        }
        let drafts = try XCTUnwrap(albums.first { $0.title == "Drafts" })
        XCTAssertNil(drafts.newestPhotoDate)
    }

    /// New photos don't change when an album was made: Iceland stays where it was.
    func testAddingPhotosDoesNotMoveAnAlbum() async {
        let library = MockPhotoLibrary()
        let before = titles(AlbumBrowsing.sorted(await library.fetchAlbums(), by: .dateCreated))
        library.addPhotos(2, toAlbum: MockPhotoLibrary.icelandAlbumID)
        let albums = await library.fetchAlbums()
        XCTAssertEqual(titles(AlbumBrowsing.sorted(albums, by: .dateCreated)), before)
        XCTAssertEqual(albums.first { $0.id == MockPhotoLibrary.icelandAlbumID }?.photoCount, 402)
    }

    // MARK: The Photos link

    func testThePhotosLinkOpensThePhotosApp() {
        XCTAssertEqual(OpenPhotosButton.photosURL?.absoluteString, "photos-redirect://")
    }

    // MARK: Helpers

    private func album(_ id: String, _ title: String, _ kind: AlbumSummary.Kind = .user, made creationRank: Int?, daysAgo: Double?) -> AlbumSummary {
        AlbumSummary(
            id: id,
            title: title,
            kind: kind,
            photoCount: daysAgo == nil ? 0 : 10,
            coverAssetID: daysAgo == nil ? nil : "\(id)-cover",
            creationRank: creationRank,
            newestPhotoDate: daysAgo.map { Date(timeIntervalSince1970: 1_790_000_000 - $0 * day) }
        )
    }

    private func visible(_ query: String) -> [String] {
        titles(AlbumBrowsing.visibleAlbums(photosOrder, matching: query, order: .photos))
    }

    private func titles(_ albums: [AlbumSummary]) -> [String] {
        albums.map(\.title)
    }
}
