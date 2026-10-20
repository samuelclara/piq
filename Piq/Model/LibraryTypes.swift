import CoreGraphics
import Foundation

/// Photos authorization, kept free of PhotoKit so views and mocks don't import Photos.
enum LibraryAccess: String, Sendable, CaseIterable {
    case notDetermined
    case authorized
    case limited
    case denied
    case restricted

    /// Whether Piq can read (and therefore sort) at least some photos.
    var canRead: Bool { self == .authorized || self == .limited }
}

/// A Photos album Piq can sort.
struct AlbumSummary: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case recents
        case favorites
        case user
    }

    /// `PHAssetCollection.localIdentifier`.
    let id: String
    let title: String
    let kind: Kind
    /// Number of photos. Videos are left out.
    let photoCount: Int
    /// The newest photo in the album, used as its cover.
    let coverAssetID: String?
}

/// What Piq shows about one photo.
struct PhotoMetadata: Hashable, Sendable {
    let id: String
    let filename: String
    let creationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int

    /// Width / height, or 3:2 when the size is unknown.
    var aspectRatio: CGFloat {
        guard pixelWidth > 0, pixelHeight > 0 else { return 3.0 / 2.0 }
        return CGFloat(pixelWidth) / CGFloat(pixelHeight)
    }

    /// "IMG_4838.HEIC · 14:32" (the time follows the person's 12/24-hour setting).
    var chipText: String {
        guard let creationDate else { return filename }
        return "\(filename) · \(creationDate.formatted(date: .omitted, time: .shortened))"
    }
}

/// What happened when Piq asked Photos to delete a batch of photos.
struct DeletionReport: Equatable, Sendable {
    /// Moved to Recently Deleted.
    var deleted: [String]
    /// Photos Piq couldn't see when it asked, so Photos wasn't asked to delete them: gone from the
    /// library or hidden, or, under limited access, possibly just outside the person's selection
    /// and still in Photos. Only if Piq had full access from the question to the answer does it
    /// treat them as gone; otherwise they stay in its trash (see `SessionController.emptyTrash()`).
    var missing: [String]
    /// Photos won't delete these (for example, photos synced from a computer).
    var undeletable: [String]
}

enum PhotoDeletionError: Error, Equatable {
    /// The person declined the system confirmation.
    case cancelled
    case failed(String)
}

/// Counted, user-facing strings.
enum Copy {
    /// "1 photo", "400 photos", "1,204 photos".
    static func photos(_ count: Int) -> String {
        count == 1 ? "1 photo" : "\(count.formatted()) photos"
    }
}
