import Foundation

/// How the picker orders the person's albums. Recents and Favorites stay first in every order.
/// The choice is a per-person convenience, kept across launches in user defaults.
enum AlbumSortOrder: String, CaseIterable, Identifiable, Sendable {
    /// The order Photos lists the albums in (the person's own arrangement there).
    case photos
    /// Newest first, in the order the person made the albums (`AlbumSummary.creationRank`):
    /// the album made last comes first, whatever its photos. PhotoKit has no public creation
    /// date for albums; it does list them in the order they were made when asked for no
    /// particular order, which is observed (iPadOS 26.5) rather than documented. An album
    /// without a rank comes after the ranked ones, by its newest photo; albums with neither last.
    case dateCreated

    /// The user-defaults key the choice is kept under.
    static let storageKey = "PiqAlbumSortOrder"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photos: "Photos order"
        case .dateCreated: "Date created"
        }
    }
}

/// Filtering and ordering the album grid: pure functions of the album list, the search text and
/// the sort order, so the grid, previews and tests agree.
enum AlbumBrowsing {
    /// The albums to show for `query`, in `order`.
    static func visibleAlbums(_ albums: [AlbumSummary], matching query: String, order: AlbumSortOrder) -> [AlbumSummary] {
        sorted(albums, by: order).filter { matches($0, query: query) }
    }

    /// The search text as it is matched: without the spaces around it.
    static func normalizedQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether `album`'s title contains `query`, ignoring case and diacritics the way Finder and
    /// Photos search do ("ICE" finds "Iceland", "cafe" finds "Café"). An empty
    /// query matches every album.
    static func matches(_ album: AlbumSummary, query: String) -> Bool {
        let query = normalizedQuery(query)
        return query.isEmpty || album.title.localizedStandardContains(query)
    }

    /// Whether the Sort control has anything to order: the person's own albums. Under limited
    /// access Piq lists Recents and Favorites only, which stay first in every order. While the
    /// albums load, the control shows, so the header doesn't shift when they arrive.
    static func offersSort(_ albums: [AlbumSummary], access: LibraryAccess, hasLoaded: Bool) -> Bool {
        guard access != .limited else { return false }
        return !hasLoaded || albums.contains { $0.kind == .user }
    }

    /// Recents and Favorites first, as Photos lists them, then the person's albums in `order`.
    /// Albums that tie keep Photos' order.
    static func sorted(_ albums: [AlbumSummary], by order: AlbumSortOrder) -> [AlbumSummary] {
        let pinned = albums.filter { $0.kind != .user }
        let own = albums.filter { $0.kind == .user }
        switch order {
        case .photos:
            return pinned + own
        case .dateCreated:
            let ordered = own.enumerated().sorted { lhs, rhs in
                if let newer = newerFirst(lhs.element.creationRank, rhs.element.creationRank) { return newer }
                if let newer = newerFirst(lhs.element.newestPhotoDate, rhs.element.newestPhotoDate) { return newer }
                return lhs.offset < rhs.offset
            }
            return pinned + ordered.map(\.element)
        }
    }

    /// Whether the left value goes first, newest first and missing values last; nil when they tie.
    private static func newerFirst<Value: Comparable>(_ left: Value?, _ right: Value?) -> Bool? {
        switch (left, right) {
        case let (left?, right?):
            left == right ? nil : left > right
        case (.some, nil):
            true
        case (nil, .some):
            false
        case (nil, nil):
            nil
        }
    }
}
