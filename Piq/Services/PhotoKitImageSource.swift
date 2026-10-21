import OSLog
@preconcurrency import Photos
import UIKit

/// `PhotoImageSource` backed by `PHCachingImageManager`. Each request is a signpost interval
/// (see `ImageSignposts`).
///
/// - Thumbnails (grids, album covers) are made at the tile's pixel size. The last few are kept
///   (`thumbnailCacheBytes`): the album covers when the picker comes back, and the rows just
///   scrolled past. Photos would decode them again.
/// - The stored preview is the thumbnail Photos keeps for the photo (`.fastFormat`, nothing
///   decoded or downloaded): nearly free, so it is asked for as soon as a photo nears the front.
///   A library without stored thumbnails (the simulator's) fails it at once, with "No resource
///   found matching image request spec".
/// - The quick preview, shown blurred while the sharp image loads, is the first image an
///   opportunistic request delivers: a stored thumbnail at once if Photos has one, otherwise a
///   512-pixel image from a reduced decode of the original (or a small download). The rest of the
///   request is then cancelled.
/// - The sharp image is the display's native resolution. The cache (`startCachingFullImages`)
///   prepares it with exactly the request's target size, content mode and options, so that a
///   photo prefetched that way is served from the cache. Photos delivers it decoded, in the
///   display's pixel format, so nothing is left to decode on the main thread when it's first
///   drawn.
///
/// Fetching a `PHAsset` waits on Photos' own queue, for milliseconds while it prepares images, so
/// assets are fetched off the main thread and kept.
@MainActor
final class PhotoKitImageSource: StoredPreviewSource {
    private let manager = PHCachingImageManager()
    private var assets: [String: PHAsset] = [:]
    /// Fetches under way, by asset ID (one fetch may cover several photos).
    private var assetFetches: [String: Task<[String: PHAsset], Never>] = [:]
    /// Caching changes, applied in the order they were asked for once their assets are fetched.
    private var cachingUpdate: Task<Void, Never>?
    /// Thumbnails delivered lately, by photo and pixel size, costed by the bytes of their bitmaps.
    private let thumbnails: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = PhotoKitImageSource.thumbnailCacheBytes
        return cache
    }()

    /// How much the thumbnail cache holds: every album cover of a typical library (a 535 × 401
    /// cover is 0.8 MB), or about two rows of the Review grid. Tiles off screen let go of their
    /// images, so the memory a grid holds stays this plus what is on screen, however far it is
    /// scrolled.
    static let thumbnailCacheBytes = 16 * 1_048_576

    /// Size of the "full resolution" image: the screen's native pixel size on its long edge,
    /// for portrait and landscape photos alike. That is as sharp as the display can show, without
    /// decoding 24–48 MP originals (100–190 MB each) for every prefetched photo.
    private lazy var fullImageSize: CGSize = {
        let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
        let native = screen?.nativeBounds.size ?? CGSize(width: 2752, height: 2064)
        let edge = max(native.width, native.height, 2048)
        return CGSize(width: edge, height: edge)
    }()

    init() {
        ImageSignposts.signposter.emitEvent("Launch")
    }

    func thumbnail(for assetID: String, pointSize: CGSize, scale: CGFloat) async -> UIImage? {
        let size = CGSize(width: pointSize.width * scale, height: pointSize.height * scale)
        let key = "\(assetID) \(Int(size.width.rounded()))x\(Int(size.height.rounded()))" as NSString
        if let cached = thumbnails.object(forKey: key) {
            ImageSignposts.signposter.emitEvent("Cached thumbnail", "\(key, privacy: .public)")
            return cached
        }
        guard let asset = await asset(for: assetID) else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        let image = await requestImage(.thumbnail, assetID, asset, size: size, contentMode: .aspectFill, options: options)
        if let image {
            thumbnails.setObject(image, forKey: key, cost: Self.bytes(of: image))
        }
        return image
    }

    func preview(for assetID: String) async -> UIImage? {
        guard let asset = await asset(for: assetID) else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return await requestImage(.preview, assetID, asset, size: CGSize(width: 512, height: 512), contentMode: .aspectFit, options: options)
    }

    func storedPreview(for assetID: String) async -> UIImage? {
        guard let asset = await asset(for: assetID) else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        return await requestImage(.storedPreview, assetID, asset, size: CGSize(width: 512, height: 512), contentMode: .aspectFit, options: options)
    }

    func fullImage(for assetID: String, progress: @escaping @MainActor @Sendable (Double) -> Void) async -> UIImage? {
        guard let asset = await asset(for: assetID) else { return nil }
        let options = Self.fullImageOptions()
        // Called on an arbitrary serial queue, and only when the photo comes from iCloud.
        options.progressHandler = { value, _, _, _ in
            Task { @MainActor in progress(value) }
        }
        return await requestImage(.full, assetID, asset, size: fullImageSize, contentMode: .aspectFit, options: options)
    }

    func zoomImage(for assetID: String) async -> UIImage? {
        guard let asset = await asset(for: assetID) else { return nil }
        let options = Self.fullImageOptions()
        return await requestImage(.zoom, assetID, asset, size: Self.zoomImageSize(of: asset), contentMode: .aspectFit, options: options)
    }

    func startCachingFullImages(for assetIDs: [String]) {
        updateCaching(of: assetIDs, start: true)
    }

    func stopCachingFullImages(for assetIDs: [String]) {
        updateCaching(of: assetIDs, start: false)
    }

    /// The most pixels a zoomed photo is decoded at: a 24 MP image holds 96 MB, where a 48 MP
    /// original would hold 190 MB. On a full-width landscape card that is one image pixel per
    /// screen pixel at about 2.5×; past it, the image is magnified.
    nonisolated static let zoomImagePixels: CGFloat = 24_000_000

    /// The photo's own size, scaled down to `zoomImagePixels` if it is larger.
    static func zoomImageSize(of asset: PHAsset) -> CGSize {
        zoomImageSize(pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight)
    }

    nonisolated static func zoomImageSize(pixelWidth: Int, pixelHeight: Int) -> CGSize {
        let width = CGFloat(max(pixelWidth, 1)), height = CGFloat(max(pixelHeight, 1))
        let factor = min(1, (zoomImagePixels / (width * height)).squareRoot())
        return CGSize(width: (width * factor).rounded(.down), height: (height * factor).rounded(.down))
    }

    // MARK: Private

    /// `.highQualityFormat` + `.exact` delivers a single sharp image no bigger than the target size.
    /// Requests and the cache must use the same options, or the cache is never used.
    private static func fullImageOptions() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true
        options.version = .current
        return options
    }

    /// Starts or stops caching after the changes asked for before, once the assets are fetched.
    private func updateCaching(of assetIDs: [String], start: Bool) {
        let previous = cachingUpdate
        cachingUpdate = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            let assets = await self.assets(for: assetIDs)
            guard !assets.isEmpty else { return }
            let size = self.fullImageSize
            if start {
                ImageSignposts.signposter.emitEvent("Caching", "start \(assets.count)")
                self.manager.startCachingImages(for: assets, targetSize: size, contentMode: .aspectFit, options: Self.fullImageOptions())
            } else {
                ImageSignposts.signposter.emitEvent("Caching", "stop \(assets.count)")
                self.manager.stopCachingImages(for: assets, targetSize: size, contentMode: .aspectFit, options: Self.fullImageOptions())
            }
        }
    }

    /// What a decoded image holds in memory.
    private static func bytes(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else {
            return Int(image.size.width * image.scale * image.size.height * image.scale) * 4
        }
        return cgImage.bytesPerRow * cgImage.height
    }

    private func asset(for id: String) async -> PHAsset? {
        await assets(for: [id]).first
    }

    /// The assets that still exist, in order. Missing ones are fetched together, off the main
    /// thread; a photo already being fetched isn't fetched again.
    private func assets(for ids: [String]) async -> [PHAsset] {
        let missing = ids.filter { assets[$0] == nil && assetFetches[$0] == nil }
        if !missing.isEmpty {
            let fetch = Task.detached(priority: .userInitiated) { Self.fetchAssets(missing) }
            for id in missing {
                assetFetches[id] = fetch
            }
        }
        var found: [PHAsset] = []
        for id in ids {
            if assets[id] == nil, let fetch = assetFetches[id] {
                keep(await fetch.value, from: fetch)
            }
            if let asset = assets[id] {
                found.append(asset)
            }
        }
        return found
    }

    /// Keeps the assets a fetch found (a few hundred at most) and forgets the fetch.
    private func keep(_ fetched: [String: PHAsset], from fetch: Task<[String: PHAsset], Never>) {
        if assets.count > 600 {
            assets.removeAll(keepingCapacity: true)
        }
        assets.merge(fetched) { _, new in new }
        assetFetches = assetFetches.filter { $0.value != fetch }
    }

    private nonisolated static func fetchAssets(_ ids: [String]) -> [String: PHAsset] {
        var result: [String: PHAsset] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in
            result[asset.localIdentifier] = asset
        }
        return result
    }

    /// The first callback resolves the request: `.highQualityFormat` calls the result handler
    /// once, and an `.opportunistic` request whose first image is a quick, degraded one is
    /// cancelled after it. A task cancelled before PhotoKit is asked gets nil without asking.
    private func requestImage(_ kind: RequestKind, _ assetID: String, _ asset: PHAsset, size: CGSize, contentMode: PHImageContentMode, options: PHImageRequestOptions) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        let signposter = ImageSignposts.signposter
        let interval = signposter.beginInterval(kind.name, id: signposter.makeSignpostID(), "\(assetID, privacy: .public) \(Int(size.width))x\(Int(size.height))")
        let manager = self.manager
        let request = PendingImageRequest()
        let delivery = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ImageDelivery, Never>) in
                guard request.begin(continuation) else { return }
                let id = manager.requestImage(for: asset, targetSize: size, contentMode: contentMode, options: options) { image, info in
                    request.finish(ImageDelivery(image: image, info: info))
                }
                request.attach(id) { manager.cancelImageRequest($0) }
            }
        } onCancel: {
            request.cancel()
        }
        if let image = delivery.image {
            let size = "\(Int(image.size.width * image.scale))x\(Int(image.size.height * image.scale))"
            signposter.endInterval(kind.name, interval, "delivered \(size, privacy: .public)\(delivery.isDegraded ? " degraded" : "", privacy: .public)")
        } else {
            signposter.endInterval(kind.name, interval, "\(Task.isCancelled ? "cancelled" : "failed", privacy: .public) \(delivery.problem ?? "", privacy: .public)")
        }
        return delivery.image
    }
}

/// What PhotoKit answered: the image, or what went wrong (for the signpost).
struct ImageDelivery: Sendable {
    var image: UIImage?
    /// A quick, low-quality first answer, with a better one to follow.
    var isDegraded = false
    var problem: String?

    static let cancelled = ImageDelivery(problem: "cancelled")

    init(image: UIImage? = nil, problem: String? = nil) {
        self.image = image
        self.problem = problem
    }

    init(image: UIImage?, info: [AnyHashable: Any]?) {
        self.image = image
        isDegraded = info?[PHImageResultIsDegradedKey] as? Bool == true
        guard image == nil else { return }
        if let error = info?[PHImageErrorKey] as? NSError {
            problem = "\(error.domain) \(error.code)"
        } else if info?[PHImageCancelledKey] as? Bool == true {
            problem = "cancelled by Photos"
        } else if info?[PHImageResultIsInCloudKey] as? Bool == true {
            problem = "in iCloud"
        } else {
            problem = "no image, info: \(info?.keys.map { "\($0)" }.sorted().joined(separator: ",") ?? "nil")"
        }
    }
}

/// The kinds of image requests, named for Instruments.
private enum RequestKind {
    case thumbnail, storedPreview, preview, full, zoom

    var name: StaticString {
        switch self {
        case .thumbnail: "Thumbnail"
        case .storedPreview: "Stored preview"
        case .preview: "Preview"
        case .full: "Full image"
        case .zoom: "Zoom image"
        }
    }
}

/// Bridges one PhotoKit image request to async/await: resumes exactly once, with PhotoKit's first
/// answer (PhotoKit may answer synchronously, asynchronously, or not at all once cancelled), and
/// cancels the PhotoKit request when the awaiting task is cancelled, or when the first answer was
/// a degraded image (nothing waits for the better one). Safe to call from any thread.
final class PendingImageRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ImageDelivery, Never>?
    private var requestID: PHImageRequestID?
    private var cancelRequest: ((PHImageRequestID) -> Void)?
    private var isCancelled = false
    private var isFinished = false
    /// Answered with a degraded image before the request ID was known: cancel it once it is.
    private var stopsWhenAttached = false

    /// Holds `continuation` until PhotoKit answers. False if the task was cancelled already: the
    /// continuation is resumed at once, and no PhotoKit request should be started.
    func begin(_ continuation: CheckedContinuation<ImageDelivery, Never>) -> Bool {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            continuation.resume(returning: .cancelled)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func attach(_ id: PHImageRequestID, cancel: @escaping (PHImageRequestID) -> Void) {
        lock.lock()
        if (isCancelled && !isFinished) || stopsWhenAttached {
            stopsWhenAttached = false
            lock.unlock()
            cancel(id)
            return
        }
        if !isFinished {
            requestID = id
            cancelRequest = cancel
        }
        lock.unlock()
    }

    func finish(_ delivery: ImageDelivery) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = self.continuation
        self.continuation = nil
        var stop: (() -> Void)?
        if delivery.isDegraded {
            if let id = requestID, let cancelRequest {
                stop = { cancelRequest(id) }
            } else {
                stopsWhenAttached = true
            }
        }
        cancelRequest = nil
        lock.unlock()
        continuation?.resume(returning: delivery)
        stop?()
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let continuation = self.continuation
        self.continuation = nil
        let id = requestID
        let cancelRequest = self.cancelRequest
        self.cancelRequest = nil
        lock.unlock()
        if let id, let cancelRequest { cancelRequest(id) }
        continuation?.resume(returning: .cancelled)
    }
}
