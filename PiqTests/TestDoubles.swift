import UIKit
@testable import Piq

/// Holds async callers until the test opens it, standing in for something that takes as long
/// as the person or Photos wants (the system deletion prompt, a slow fetch).
@MainActor
final class Gate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    /// Whether a caller is waiting here.
    var isHolding: Bool { !waiting.isEmpty }

    func pass() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Lets everyone through, now and from now on.
    func open() {
        isOpen = true
        let held = waiting
        waiting = []
        for caller in held { caller.resume() }
    }
}

/// A library that answers however the test says. Its gates hold deletions, album listings or
/// album lookups back until the test opens them. A held listing or lookup answers with what
/// Photos had when it was asked, the way a slow PhotoKit fetch does.
@MainActor
final class StubPhotoLibrary: PhotoLibraryClient {
    var access: LibraryAccess = .authorized
    var onChange: (@MainActor () -> Void)?
    /// What the person answers when `requestAccess()` asks for the first time.
    var answerToAccessRequest: LibraryAccess = .authorized
    /// What `fetchAlbums` lists.
    var albums: [AlbumSummary] = []
    /// What `assetIDs(inAlbum:)` answers, by album ID; albums missing here don't exist.
    var albumContents: [String: [String]] = [:]
    /// What `deleteAssets` returns or throws.
    var deletionResult: Result<DeletionReport, PhotoDeletionError> = .success(DeletionReport(deleted: [], missing: [], undeletable: []))
    /// Deletions wait here, the way the system prompt waits for the person.
    var deletionGate: Gate?
    /// The next album listing waits here (one listing per gate).
    var albumListGate: Gate?
    /// The next lookup of an album waits here, by album ID (one lookup per gate).
    var albumGates: [String: Gate] = [:]
    /// Album lookups that have answered.
    private(set) var answeredLookups = 0
    /// Every batch Piq asked to delete, in order.
    private(set) var deletionRequests: [[String]] = []

    func requestAccess() async -> LibraryAccess {
        if access == .notDetermined {
            access = answerToAccessRequest
        }
        return access
    }

    func fetchAlbums() async -> [AlbumSummary] {
        let listed = albums
        if let gate = albumListGate {
            albumListGate = nil
            await gate.pass()
        }
        return listed
    }

    func assetIDs(inAlbum albumID: String) async -> [String]? {
        let contents = albumContents[albumID]
        if let gate = albumGates.removeValue(forKey: albumID) {
            await gate.pass()
        }
        answeredLookups += 1
        return contents
    }

    func metadata(for assetIDs: [String]) async -> [String: PhotoMetadata] { [:] }

    func deleteAssets(_ assetIDs: [String]) async throws -> DeletionReport {
        deletionRequests.append(assetIDs)
        await deletionGate?.pass()
        return try deletionResult.get()
    }

    func presentLimitedLibraryPicker() {}
}

/// An image source with no images that records the prefetch hints it gets.
@MainActor
final class SpyImageSource: PhotoImageSource {
    private(set) var startedCaching: [[String]] = []
    private(set) var stoppedCaching: [[String]] = []

    func thumbnail(for assetID: String, pointSize: CGSize, scale: CGFloat) async -> UIImage? { nil }

    func preview(for assetID: String) async -> UIImage? { nil }

    func fullImage(for assetID: String, progress: @escaping @MainActor @Sendable (Double) -> Void) async -> UIImage? { nil }

    func startCachingFullImages(for assetIDs: [String]) {
        startedCaching.append(assetIDs)
    }

    func stopCachingFullImages(for assetIDs: [String]) {
        stoppedCaching.append(assetIDs)
    }
}
