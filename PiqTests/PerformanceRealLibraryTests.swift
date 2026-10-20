import Darwin
import Photos
import SwiftUI
import XCTest
@testable import Piq

/// Image loading on a real photo library. The image source: previews arrive, sharp images are
/// screen-sized and ready to display, prefetched photos come from the cache. The sorting window,
/// when it opens and while sorting at a steady pace and in bursts faster than UI tests can type:
/// is each photo sharp by the time it reaches the front, how long is it shown blurred otherwise,
/// how many requests are made and cancelled, and what it costs. The album list with user albums
/// and favorites, and the memory a long Review grid holds.
///
/// Drives `PhotoWindowLoader` and `PhotoKitImageSource` the way the sorting deck does: at each
/// decision the next photo moves to the front at once, and the window moves on when the card has
/// flown off (277 ms later) or when the next decision comes first.
///
/// Gated: runs only with `TEST_RUNNER_PIQ_E2E=1`, in a test host with full Photos access to a
/// library of 400+ full-resolution photos (see `PerformanceSortingTests` for preparing one).
/// `testTheAlbumListWithUserAlbumsAndFavorites` adds ten albums ("Piq Perf 01" to "10") and 24
/// favorites to that library the first time (no prompt), and keeps them.
/// `TEST_RUNNER_PIQ_PERF_CPU_LOAD=<n>` keeps n threads busy during each test, standing in for a
/// slower device or a busy host.
@MainActor
final class PerformanceRealLibraryTests: XCTestCase {
    private static let flight: Duration = .milliseconds(277)
    private var load: CPULoad?

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PIQ_E2E"] == "1", "Needs a prepared photo library: TEST_RUNNER_PIQ_E2E=1")
        try XCTSkipUnless(PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized, "Needs full Photos access")
        if let threads = ProcessInfo.processInfo.environment["PIQ_PERF_CPU_LOAD"].flatMap(Int.init), threads > 0 {
            load = CPULoad(threads: threads)
        }
    }

    override func tearDown() async throws {
        load?.stop()
        load = nil
    }

    /// One decision every 0.6 s: every photo is sharp before it reaches the front.
    func testSteadyPaceShowsEveryPhotoSharp() async throws {
        let ids = try recents(from: 40, count: 60)
        let keys = (0..<40).map { Duration.milliseconds(600 * $0) }
        let run = try await sort(ids, keys: keys)
        attach(run, "steady")
        XCTAssertEqual(run.sharpOnArrival, run.fronts.count, "every photo is sharp when it reaches the front")
        XCTAssertEqual(run.fullRequests.filter { $0.delivered }.count, Set(run.fullRequests.map(\.assetID)).count, "each photo is delivered once")
    }

    /// Bursts of five decisions within a second (200 ms apart), then a 1.5 s pause.
    func testBurstsCatchUpQuickly() async throws {
        let ids = try recents(from: 140, count: 60)
        var keys: [Duration] = []
        for burst in 0..<6 {
            for index in 0..<5 {
                keys.append(.milliseconds(burst * 2500 + index * 200))
            }
        }
        let run = try await sort(ids, keys: keys)
        attach(run, "bursts")
        let late = run.fronts.compactMap(\.wait)
        XCTAssertTrue(late.allSatisfy { $0 < .seconds(1) }, "photos shown before they're sharp sharpen within a second: \(late)")
        XCTAssertTrue(run.fronts.allSatisfy { $0.wasSharp || $0.hadPreview || $0.wait.map { $0 < .milliseconds(150) } == true },
                      "a photo that isn't sharp yet shows its preview")
    }

    /// Opening sorting on photos not loaded before (ten times, four new photos each): how soon the
    /// current photo shows, blurred and then sharp, and how soon the next one is sharp.
    func testOpeningShowsTheCurrentPhotoSharpQuickly() async throws {
        let ids = try recents(from: 360, count: 40)
        let clock = ContinuousClock()
        var lines: [String] = []
        var sharp: [Duration] = []
        for round in 0..<10 {
            let window = Array(ids[(round * 4)..<(round * 4 + 4)])
            let loader = PhotoWindowLoader(images: PhotoKitImageSource(), library: PhotoKitLibraryClient())
            let cpuStart = Self.cpuTime()
            let start = clock.now
            loader.show(window)
            var preview, current, next: Duration?
            while clock.now - start < .seconds(3), current == nil || next == nil {
                let now = clock.now - start
                if preview == nil, loader.slot(for: window[0])?.displayImage != nil { preview = now }
                if current == nil, loader.slot(for: window[0])?.isSharp == true { current = now }
                if next == nil, loader.slot(for: window[1])?.isSharp == true { next = now }
                try await Task.sleep(for: .milliseconds(2))
            }
            // Until the photos further ahead are cached and requested too.
            try await clock.sleep(until: start + .seconds(1.5))
            let cpu = Self.cpuTime() - cpuStart
            loader.releaseAll()
            sharp.append(try XCTUnwrap(current, "round \(round): the current photo is sharp within 3 s"))
            lines.append("round \(round): first image \(Self.ms(preview)), sharp \(Self.ms(current)), next sharp \(Self.ms(next)); CPU \(Int(cpu * 1000)) ms")
            try await Task.sleep(for: .milliseconds(300))
        }
        report(lines, "opening")
        XCTAssertLessThan(sharp.sorted()[sharp.count / 2], .milliseconds(500), "the current photo is usually sharp within half a second")
    }

    // MARK: The image source

    /// A quick preview comes back for every kind of photo, small and in the photo's shape
    /// (`.fastFormat` failed them all on a library without stored thumbnails).
    func testPreviewsArriveSmallAndInThePhotosShape() async throws {
        let images = PhotoKitImageSource()
        let clock = ContinuousClock()
        var lines: [String] = []
        for photo in try photosOfEveryKind() {
            let start = clock.now
            let preview = await images.preview(for: photo.id)
            let elapsed = clock.now - start
            let size = try Self.pixelSize(of: XCTUnwrap(preview, "a preview for \(photo)"))
            XCTAssertLessThanOrEqual(max(size.width, size.height), 1024, "\(photo): a small image, \(size)")
            XCTAssertEqual(size.width / size.height, photo.aspectRatio, accuracy: 0.05, "\(photo): the photo's shape, \(size)")
            let storedStart = clock.now
            let stored = await images.storedPreview(for: photo.id)
            let storedTime = Int((clock.now - storedStart) / .milliseconds(1))
            if let stored {
                let storedSize = Self.pixelSize(of: stored)
                XCTAssertLessThanOrEqual(max(storedSize.width, storedSize.height), 1024, "\(photo): a small stored preview, \(storedSize)")
            }
            lines.append("\(photo): preview \(Int(size.width))x\(Int(size.height)) in \(Int(elapsed / .milliseconds(1))) ms; "
                + "stored preview \(stored.map { "\(Int(Self.pixelSize(of: $0).width))x\(Int(Self.pixelSize(of: $0).height))" } ?? "none") in \(storedTime) ms")
        }
        report(lines, "previews")
    }

    /// The sharp image is the screen's size (the original's, if that is smaller), already decoded
    /// in the display's pixel format, so its first draw on the main thread has nothing left to
    /// decode.
    func testFullImagesAreScreenSizedAndReadyToDisplay() async throws {
        let images = PhotoKitImageSource()
        let native = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first).nativeBounds.size
        let edge = max(native.width, native.height, 2048)
        for photo in try photosOfEveryKind() {
            let full = await images.fullImage(for: photo.id) { _ in }
            let image = try XCTUnwrap(full, "\(photo)")
            let cgImage = try XCTUnwrap(image.cgImage)
            XCTAssertEqual(CGFloat(max(cgImage.width, cgImage.height)), min(edge, CGFloat(max(photo.width, photo.height))), "\(photo): the screen's long edge")
            XCTAssertEqual(CGFloat(cgImage.width) / CGFloat(cgImage.height), photo.aspectRatio, accuracy: 0.01, "\(photo)")
            XCTAssertEqual(cgImage.bitsPerPixel, 32)
            XCTAssertEqual(cgImage.bitmapInfo.intersection(.byteOrderMask), .byteOrder32Little, "BGRA/BGRX, what Core Animation draws as is")
            let prepared = await image.byPreparingForDisplay()
            XCTAssertTrue(prepared?.cgImage === cgImage, "\(photo): nothing left to prepare")
        }
    }

    /// Photos the loader prefetches are served from the cache when requested.
    func testPrefetchedPhotosComeFromTheCache() async throws {
        let images = PhotoKitImageSource()
        let clock = ContinuousClock()
        func load(_ ids: [String]) async -> [Duration] {
            var times: [Duration] = []
            for id in ids {
                let start = clock.now
                _ = await images.fullImage(for: id) { _ in }
                times.append(clock.now - start)
            }
            return times
        }
        let cold = await load(try recents(from: 240, count: 5))
        let prefetched = try recents(from: 250, count: 5)
        images.startCachingFullImages(for: prefetched)
        try await Task.sleep(for: .seconds(3))
        let cached = await load(prefetched)
        images.stopCachingFullImages(for: prefetched)
        report(["full images: cold \(cold.map { Int($0 / .milliseconds(1)) }) ms, prefetched \(cached.map { Int($0 / .milliseconds(1)) }) ms"], "cache")
        XCTAssertLessThan(cached.sorted()[2], .milliseconds(20), "served from the cache")
        XCTAssertLessThan(cached.sorted()[2], cold.sorted()[2])
    }

    /// An arrow key held down: key repeat decides a photo every 70 ms, twenty in a row. Photos
    /// skipped this fast mustn't leave decodes running, and the photo where the key is let go is
    /// sharp soon after.
    func testHoldingAnArrowKeyLeavesNoBacklog() async throws {
        let ids = try recents(from: 280, count: 70)
        var keys: [Duration] = []
        for round in 0..<2 {
            for index in 0..<20 {
                keys.append(.milliseconds(round * 4000 + index * 70))
            }
        }
        let run = try await sort(ids, keys: keys)
        attach(run, "key-repeat")
        let settled = [run.fronts[19], run.fronts[39]]
        for front in settled {
            XCTAssertLessThan(front.wait ?? .zero, .seconds(1), "the photo where the key is let go sharpens within a second")
        }
        let full = run.fullRequests
        XCTAssertTrue(full.allSatisfy { $0.delivered || $0.cancelled }, "a request that didn't deliver was cancelled: its photo left the window")
        XCTAssertEqual(full.count, Set(full.map(\.assetID)).count, "no photo requested twice")
        XCTAssertLessThanOrEqual(run.peakFullRequestsInFlight, PhotoWindowLoader.lookahead + 1, "never more requests under way than photos in the window")
        XCTAssertEqual(run.fullRequestsInFlightAtEnd, 0, "nothing left running once the window is released")
    }

    // MARK: The album picker and the Review grid

    /// Recents, Favorites and ten user albums: how long the list takes with its counts and
    /// covers, and the cover sizes asked for, new and again.
    func testTheAlbumListWithUserAlbumsAndFavorites() async throws {
        try await Self.prepareAlbumsAndFavorites(from: recentsIDs())
        let clock = ContinuousClock()
        var listings: [Duration] = []
        var albums: [AlbumSummary] = []
        for _ in 0..<5 {
            let library = PhotoKitLibraryClient()
            let start = clock.now
            albums = await library.fetchAlbums()
            listings.append(clock.now - start)
        }
        XCTAssertEqual(albums.filter { $0.title.hasPrefix(Self.albumPrefix) }.count, 10, "the ten albums")
        XCTAssertGreaterThanOrEqual(albums.first { $0.kind == .favorites }?.photoCount ?? 0, Self.favoriteCount)
        XCTAssertTrue(albums.allSatisfy { $0.photoCount == 0 || $0.coverAssetID != nil }, "every album with photos has a cover")

        // The covers as the picker's tiles ask for them (267.5 × 172 pt at 2× in landscape).
        let images = PhotoKitImageSource()
        let tile = CGSize(width: 267.5, height: 172)
        var sizes: Set<String> = []
        func loadCovers() async -> [Duration] {
            var times: [Duration] = []
            for cover in albums.compactMap(\.coverAssetID) {
                let start = clock.now
                if let image = await images.thumbnail(for: cover, pointSize: tile, scale: 2) {
                    sizes.insert("\(Int(image.size.width * image.scale))x\(Int(image.size.height * image.scale))")
                }
                times.append(clock.now - start)
            }
            return times
        }
        let cold = await loadCovers()
        let again = await loadCovers()
        report([
            "albums \(albums.count): \(albums.map { "\($0.title) \($0.photoCount)" }.joined(separator: ", "))",
            "listing with counts and covers: \(listings.map { Int($0 / .milliseconds(1)) }) ms",
            "covers asked for 535x344 px, delivered \(sizes.sorted()); new \(cold.map { Int($0 / .milliseconds(1)) }) ms, again \(again.map { Int($0 / .milliseconds(1)) }) ms",
        ], "album-list")
        XCTAssertEqual(cold.count, albums.count, "one cover per album")
        XCTAssertLessThan(again.max() ?? .zero, .milliseconds(5), "covers shown again (the picker coming back) come from the image source's cache")
    }

    /// A Review grid of 400 marked photos (6 columns of 178.5 pt tiles in a 1194 × 834 window),
    /// scrolled to the end and back: the memory it holds stays flat, however far it's scrolled.
    func testALongReviewGridKeepsItsMemoryFlat() async throws {
        let ids = try recents(from: 0, count: 400)
        let images = RecordingImageSource(base: PhotoKitImageSource())
        let app = AppModel(library: PhotoKitLibraryClient(), images: images, container: PreviewSupport.inMemoryContainer())
        let scroll = GridScroll()
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw XCTSkip("No window scene to render into")
        }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1194, height: 834)
        window.rootViewController = UIHostingController(rootView: ReviewLikeGrid(photos: ids, scroll: scroll).environment(app))
        window.isHidden = false
        defer { window.isHidden = true }

        try await Task.sleep(for: .seconds(2))
        let start = Self.footprint()
        var samples: [(row: Int, footprint: UInt64)] = []
        let rows = (ids.count + 5) / 6
        for row in stride(from: 2, through: rows - 1, by: 2) {
            scroll.target = ids[row * 6]
            try await Task.sleep(for: .milliseconds(400))
            samples.append((row, Self.footprint()))
        }
        try await Task.sleep(for: .seconds(2))
        let bottom = Self.footprint()
        let requestedGoingDown = images.requests.filter { $0.kind == "thumbnail" }.count
        scroll.target = ids[0]
        try await Task.sleep(for: .seconds(2))
        let top = Self.footprint()
        let thumbnails = images.requests.filter { $0.kind == "thumbnail" }

        let early = try XCTUnwrap(samples.first { $0.row >= 10 }).footprint
        let peak = samples.map(\.footprint).max() ?? 0
        let mb = { (bytes: UInt64) in Int(bytes / 1_048_576) }
        report([
            "footprint (MB): start \(mb(start)), after 60 tiles \(mb(early)), peak \(mb(peak)), at the end \(mb(bottom)), back at the top \(mb(top))",
            "  by row: \(samples.map { "\($0.row):\(mb($0.footprint))" }.joined(separator: " "))",
            "thumbnails asked for: \(requestedGoingDown) going down (\(Set(thumbnails.prefix(requestedGoingDown).map(\.assetID)).count) photos), "
                + "delivered in p50 \(Self.p50(thumbnails.prefix(requestedGoingDown))) ms; \(thumbnails.count - requestedGoingDown) coming back, "
                + "delivered in p50 \(Self.p50(thumbnails.dropFirst(requestedGoingDown))) ms",
        ], "review-grid-memory")
        XCTAssertLessThan(mb(peak) - mb(early), 48, "flat: tiles off screen let go of their images")
        withExtendedLifetime(app) {}
    }

    // MARK: Driving the loader

    private struct Front {
        let assetID: String
        let wasSharp: Bool
        let hadPreview: Bool
        /// How long until its sharp image arrived (nil: sharp on arrival).
        var wait: Duration?
        /// How long it stayed in front (nil: until the end).
        var shownFor: Duration?

        /// How long it was in front without its sharp image.
        var unsharpOnScreen: Duration? {
            guard let wait else { return nil }
            return shownFor.map { min($0, wait) } ?? wait
        }
    }

    private struct Run {
        var fronts: [Front] = []
        var fullRequests: [RecordingImageSource.Request] = []
        var previewRequests: [RecordingImageSource.Request] = []
        var cpu: Double = 0
        var peakFootprint: UInt64 = 0
        var peakFullRequestsInFlight = 0
        var fullRequestsInFlightAtEnd = 0
        var sharpOnArrival: Int { fronts.filter(\.wasSharp).count }
    }

    /// Sorts `ids` from the start with a decision at each of `keys` (offsets from the start).
    private func sort(_ ids: [String], keys: [Duration]) async throws -> Run {
        let images = RecordingImageSource(base: PhotoKitImageSource())
        let loader = PhotoWindowLoader(images: images, library: PhotoKitLibraryClient())
        var state = SortingState(assetIDs: ids)
        loader.show(state.window(lookahead: PhotoWindowLoader.lookahead))
        // The screen opened: let the first window load before the clock starts.
        try await Task.sleep(for: .seconds(2))
        images.reset()

        var run = Run()
        var watchers: [Task<Duration?, Never>] = []
        let cpuStart = Self.cpuTime()
        let clock = ContinuousClock()
        let start = clock.now
        var pending = false
        for (index, key) in keys.enumerated() {
            try await clock.sleep(until: start + key)
            if pending {
                _ = state.apply(.keep)
                loader.show(state.window(lookahead: PhotoWindowLoader.lookahead))
                pending = false
            }
            // The card behind moves to the front now.
            guard let next = state.upcomingAssetIDs(1).first, let slot = loader.slot(for: next) else { continue }
            if let previous = run.fronts.indices.last {
                run.fronts[previous].shownFor = clock.now - (start + keys[previous])
            }
            run.fronts.append(Front(assetID: next, wasSharp: slot.isSharp, hadPreview: slot.preview != nil))
            watchers.append(Task { await Self.waitUntilSharp(slot, since: clock.now) })
            pending = true
            let landing = start + key + Self.flight
            let nextKey = index + 1 < keys.count ? start + keys[index + 1] : landing
            if landing <= nextKey {
                try await clock.sleep(until: landing)
                _ = state.apply(.keep)
                loader.show(state.window(lookahead: PhotoWindowLoader.lookahead))
                pending = false
            }
            run.peakFootprint = max(run.peakFootprint, Self.footprint())
        }
        try await Task.sleep(for: .seconds(1.5))
        for (index, watcher) in watchers.enumerated() {
            run.fronts[index].wait = run.fronts[index].wasSharp ? nil : await watcher.value
        }
        run.cpu = Self.cpuTime() - cpuStart
        run.fullRequests = images.requests.filter { $0.kind == "full" }
        run.previewRequests = images.requests.filter { $0.kind != "full" }
        run.peakFullRequestsInFlight = images.peakInFlight["full"] ?? 0
        loader.releaseAll()
        try await Task.sleep(for: .milliseconds(200))
        run.fullRequestsInFlightAtEnd = images.inFlight["full"] ?? 0
        return run
    }

    private static func waitUntilSharp(_ slot: PhotoSlot, since start: ContinuousClock.Instant) async -> Duration? {
        let clock = ContinuousClock()
        while !slot.isSharp {
            guard clock.now - start < .seconds(3) else { return nil }
            try? await Task.sleep(for: .milliseconds(4))
        }
        return clock.now - start
    }

    // MARK: Library and measurements

    private static let albumPrefix = "Piq Perf "
    private static let favoriteCount = 24

    /// Ten user albums of 18 to 45 photos ("Piq Perf 01" to "10") and 24 favorites, made once.
    private static func prepareAlbumsAndFavorites(from ids: [String]) async throws {
        var titles: Set<String> = []
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil).enumerateObjects { album, _, _ in
            titles.insert(album.localizedTitle ?? "")
        }
        let favorites = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumFavorites, options: nil).firstObject
            .map { PHAsset.fetchAssets(in: $0, options: nil).count } ?? 0
        let prefix = albumPrefix
        let favoriteCount = favoriteCount
        let missing = (1...10).filter { !titles.contains(String(format: "\(prefix)%02d", $0)) }
        guard !missing.isEmpty || favorites < favoriteCount, ids.count >= 400 else { return }
        try await PHPhotoLibrary.shared().performChanges {
            for index in missing {
                let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: String(format: "\(prefix)%02d", index))
                let first = index * 36
                request.addAssets(PHAsset.fetchAssets(withLocalIdentifiers: Array(ids[first..<(first + 15 + 3 * index)]), options: nil))
            }
            if favorites < favoriteCount {
                PHAsset.fetchAssets(withLocalIdentifiers: Array(ids[300..<(300 + favoriteCount)]), options: nil).enumerateObjects { asset, _, _ in
                    PHAssetChangeRequest(for: asset).isFavorite = true
                }
            }
        }
    }

    /// `count` photos of Recents, oldest first, from position `offset`.
    private func recents(from offset: Int, count: Int) throws -> [String] {
        let ids = try recentsIDs()
        try XCTSkipIf(ids.count < offset + count, "Recents has \(ids.count) photos; the test needs \(offset + count)")
        return Array(ids[offset..<(offset + count)])
    }

    /// Recents as Piq sorts it: its photos, oldest first.
    private func recentsIDs() throws -> [String] {
        let recents = try XCTUnwrap(PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumUserLibrary, options: nil).firstObject, "Recents")
        return try XCTUnwrap(PhotoKitQueries.assetIDs(inAlbum: recents.localIdentifier))
    }

    /// A photo of Recents, with what PhotoKit says about it.
    private struct LibraryPhoto: CustomStringConvertible {
        let id: String
        let filename: String
        let width: Int
        let height: Int

        var aspectRatio: CGFloat { CGFloat(width) / CGFloat(height) }
        var description: String { "\(filename) \(width)x\(height)" }
    }

    /// One photo of each format and size in Recents: 12 MP JPEG and HEIC in both orientations,
    /// 48 MP JPEG and HEIC, and the simulator's own sample photos.
    private func photosOfEveryKind() throws -> [LibraryPhoto] {
        var kinds: [String: LibraryPhoto] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: try recentsIDs(), options: nil).enumerateObjects { asset, _, _ in
            guard let resource = PHAssetResource.assetResources(for: asset).first else { return }
            let kind = "\(resource.uniformTypeIdentifier) \(asset.pixelWidth)x\(asset.pixelHeight)"
            if kinds[kind] == nil {
                kinds[kind] = LibraryPhoto(id: asset.localIdentifier, filename: resource.originalFilename, width: asset.pixelWidth, height: asset.pixelHeight)
            }
        }
        let photos = kinds.values.sorted { $0.filename < $1.filename }
        try XCTSkipUnless(photos.contains { $0.width * $0.height > 40_000_000 }, "Needs the prepared library (48 MP photos)")
        return photos
    }

    /// The median time the delivered requests took, in milliseconds.
    private static func p50(_ requests: ArraySlice<RecordingImageSource.Request>) -> Int {
        let times = requests.filter(\.delivered).compactMap(\.duration).map { Int($0 / .milliseconds(1)) }.sorted()
        return times.isEmpty ? -1 : times[times.count / 2]
    }

    /// "123 ms", or "-" for something that never happened.
    private static func ms(_ value: Duration?) -> String {
        value.map { "\(Int($0 / .milliseconds(1))) ms" } ?? "-"
    }

    private static func pixelSize(of image: UIImage) -> CGSize {
        CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }

    /// Prints the lines and attaches them to the test.
    private func report(_ lines: [String], _ name: String) {
        let text = lines.joined(separator: "\n")
        print(text)
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private static func cpuTime() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }

    private static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private func attach(_ run: Run, _ name: String) {
        let waits = run.fronts.compactMap(\.wait).map { Int($0 / .milliseconds(1)) }.sorted()
        let full = run.fullRequests
        let fullDurations = full.filter(\.delivered).compactMap(\.duration).map { Int($0 / .milliseconds(1)) }.sorted()
        func pct(_ values: [Int], _ p: Double) -> Int { values.isEmpty ? -1 : values[min(values.count - 1, Int(Double(values.count - 1) * p))] }
        let onScreen = run.fronts.compactMap(\.unsharpOnScreen).map { Int($0 / .milliseconds(1)) }.sorted()
        let stored = run.previewRequests.filter { $0.kind == "stored" }
        let decoded = run.previewRequests.filter { $0.kind == "preview" }
        let lines = [
            "\(name): \(run.fronts.count) photos reached the front; sharp on arrival \(run.sharpOnArrival); "
                + "blurred \(run.fronts.filter { !$0.wasSharp && $0.hadPreview }.count); placeholder \(run.fronts.filter { !$0.wasSharp && !$0.hadPreview }.count)",
            "  time to sharp after reaching the front (ms): \(waits) p50 \(pct(waits, 0.5)) p90 \(pct(waits, 0.9))",
            "  time in front without the sharp image (ms): \(onScreen) max \(onScreen.last ?? 0)",
            "  full requests \(full.count) (delivered \(full.filter(\.delivered).count), cancelled \(full.filter(\.cancelled).count), "
                + "photos \(Set(full.map(\.assetID)).count)); delivered in p50 \(pct(fullDurations, 0.5)) p90 \(pct(fullDurations, 0.9)) max \(fullDurations.last ?? -1) ms",
            "  stored previews \(stored.count) (delivered \(stored.filter(\.delivered).count)); decoded previews \(decoded.count) (delivered \(decoded.filter(\.delivered).count), cancelled \(decoded.filter(\.cancelled).count))",
            "  full requests in flight at most \(run.peakFullRequestsInFlight), at the end \(run.fullRequestsInFlightAtEnd)",
            "  CPU \(Int(run.cpu * 1000)) ms (\(Int(run.cpu * 1000) / max(run.fronts.count, 1)) ms per photo); peak footprint \(run.peakFootprint / 1_048_576) MB",
        ]
        let late = run.fronts.filter { $0.wait != nil || !$0.wasSharp }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: late.map(\.assetID), options: nil)
        var sizes: [String: String] = [:]
        assets.enumerateObjects { asset, _, _ in
            let name = PHAssetResource.assetResources(for: asset).first?.originalFilename ?? "?"
            sizes[asset.localIdentifier] = "\(name) \(asset.pixelWidth)x\(asset.pixelHeight)"
        }
        let lateLines = late.map { front in
            let full = run.fullRequests.first { $0.assetID == front.assetID }
            let preview = decoded.first { $0.assetID == front.assetID }
            return "  not sharp on arrival: \(sizes[front.assetID] ?? front.assetID), sharp after \(front.wait.map { "\(Int($0 / .milliseconds(1))) ms" } ?? "never"), "
                + "in front for \(front.shownFor.map { "\(Int($0 / .milliseconds(1))) ms" } ?? "the rest of the run"), "
                + "full request took \(full?.duration.map { "\(Int($0 / .milliseconds(1))) ms" } ?? "-"), preview \(preview.map { $0.delivered ? "delivered" : ($0.cancelled ? "cancelled" : "failed") } ?? "not requested")"
        }
        report(lines + lateLines, "window-loader-\(name)")
    }
}

/// Forwards to another image source and records every request: kind, photo, timing, outcome, and
/// how many of each kind are under way.
@MainActor
private final class RecordingImageSource: StoredPreviewSource {
    struct Request {
        let id: Int
        let kind: String
        let assetID: String
        let start: ContinuousClock.Instant
        var duration: Duration?
        var delivered = false
        var cancelled = false
    }

    private(set) var requests: [Request] = []
    private(set) var inFlight: [String: Int] = [:]
    private(set) var peakInFlight: [String: Int] = [:]
    /// The kind of every request under way, by ID (also those from before `reset()`).
    private var kinds: [Int: String] = [:]
    private var requestCount = 0
    private let base: any PhotoImageSource

    init(base: any PhotoImageSource) {
        self.base = base
    }

    func reset() {
        requests = []
        peakInFlight = inFlight
    }

    func thumbnail(for assetID: String, pointSize: CGSize, scale: CGFloat) async -> UIImage? {
        let id = begin("thumbnail", assetID)
        let image = await base.thumbnail(for: assetID, pointSize: pointSize, scale: scale)
        end(id, image)
        return image
    }

    func storedPreview(for assetID: String) async -> UIImage? {
        guard let base = base as? any StoredPreviewSource else { return nil }
        let id = begin("stored", assetID)
        let image = await base.storedPreview(for: assetID)
        end(id, image)
        return image
    }

    func preview(for assetID: String) async -> UIImage? {
        let id = begin("preview", assetID)
        let image = await base.preview(for: assetID)
        end(id, image)
        return image
    }

    func fullImage(for assetID: String, progress: @escaping @MainActor @Sendable (Double) -> Void) async -> UIImage? {
        let id = begin("full", assetID)
        let image = await base.fullImage(for: assetID, progress: progress)
        end(id, image)
        return image
    }

    func startCachingFullImages(for assetIDs: [String]) {
        base.startCachingFullImages(for: assetIDs)
    }

    func stopCachingFullImages(for assetIDs: [String]) {
        base.stopCachingFullImages(for: assetIDs)
    }

    private func begin(_ kind: String, _ assetID: String) -> Int {
        inFlight[kind, default: 0] += 1
        peakInFlight[kind] = max(peakInFlight[kind] ?? 0, inFlight[kind] ?? 0)
        requestCount += 1
        kinds[requestCount] = kind
        requests.append(Request(id: requestCount, kind: kind, assetID: assetID, start: ContinuousClock.now))
        return requestCount
    }

    /// Requests made before `reset()` end without a record.
    private func end(_ id: Int, _ image: UIImage?) {
        if let kind = kinds.removeValue(forKey: id) {
            inFlight[kind, default: 1] -= 1
        }
        guard let index = requests.firstIndex(where: { $0.id == id }) else { return }
        requests[index].duration = ContinuousClock.now - requests[index].start
        requests[index].delivered = image != nil
        requests[index].cancelled = image == nil && Task.isCancelled
    }
}

@MainActor
@Observable
private final class GridScroll {
    var target: String?
}

/// The Review grid's layout at 1194 × 834: six columns of square tiles, 12 pt gaps, 40 pt margins.
private struct ReviewLikeGrid: View {
    let photos: [String]
    let scroll: GridScroll

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 6), spacing: 12) {
                    ForEach(photos, id: \.self) { id in
                        AssetThumbnail(assetID: id, pointSize: CGSize(width: 178.5, height: 178.5))
                            .aspectRatio(1, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .id(id)
                    }
                }
                .padding(.horizontal, 40)
            }
            .onChange(of: scroll.target) { _, target in
                if let target {
                    proxy.scrollTo(target, anchor: .top)
                }
            }
        }
    }
}

/// Threads that keep the CPU busy until stopped.
private final class CPULoad: @unchecked Sendable {
    private let lock = NSLock()
    private var isRunning = true

    init(threads: Int) {
        for _ in 0..<threads {
            let thread = Thread { [self] in
                var value = 0.0
                while running {
                    for step in 0..<20_000 {
                        value += sin(Double(step))
                    }
                }
                _ = value
            }
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    private var running: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRunning
    }

    func stop() {
        lock.lock()
        isRunning = false
        lock.unlock()
    }
}
