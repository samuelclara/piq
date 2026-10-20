import Observation
import OSLog
import UIKit

/// One photo in the sorting window: its metadata and its sharp image, with a blurry preview
/// first when the library keeps one or the sharp image is slow to come.
@MainActor
@Observable
final class PhotoSlot: Identifiable {
    let id: String
    var metadata: PhotoMetadata?
    var preview: UIImage?
    var image: UIImage?
    /// Non-nil while the sharp image is downloading from iCloud.
    var downloadProgress: Double?
    /// The sharp image couldn't be loaded (the preview stays on screen).
    var didFail = false

    init(id: String) {
        self.id = id
    }

    var isSharp: Bool { image != nil }
    var displayImage: UIImage? { image ?? preview }
}

/// Keeps the current photo and the next `lookahead` photos loaded at full resolution and
/// releases everything else, so sorting 400+ photos stays fast and memory stays flat.
///
/// What is on screen comes first. The current photo and the next one (it peeks out behind the
/// current photo, and is in front as soon as a swipe starts) are requested right away, sharp image
/// first. A photo further ahead is requested at once too when those two are sharp already (while
/// sorting, the photo that joins the window), so it has the most time before it reaches the front.
/// When they aren't (the window is new, or the front is still loading), it waits instead: it is
/// prefetched by the image source's cache and requested once the cache has had `cacheLead` to
/// prepare it, or as soon as it moves up. Requesting a photo while the cache is still preparing it
/// would decode it a second time, so a photo requested at once isn't cached.
///
/// A photo two decisions or less from the front that isn't sharp asks at once for the preview the
/// library keeps (`StoredPreviewSource`, nearly free), and, when its sharp image is late
/// (`previewLead` after it was asked for) or fails and there is no stored preview, for a quick
/// preview decoded from the original. Photos that leave the window are released and their
/// requests cancelled.
@MainActor
@Observable
final class PhotoWindowLoader {
    /// How many photos after the current one are prefetched.
    static let lookahead = 3
    /// How long a photo two or more places ahead waits, when the photos in front aren't sharp yet,
    /// before its sharp image is requested: time for the cache to prepare a 12 MP photo, and short
    /// enough that it is in by the time it reaches the front.
    static let cacheLead: Duration = .milliseconds(250)
    /// How long a photo near the front waits for its sharp image, once asked for, before a quick
    /// preview is decoded for it (when the library keeps none). A photo on the device is usually
    /// sharp by then, and a preview's decode would only slow its sharp image down; one that is slow
    /// to come (a download, a 48 MP original) shows its preview soon after.
    static let previewLead: Duration = .milliseconds(120)

    private(set) var slots: [String: PhotoSlot] = [:]
    @ObservationIgnored private var loads: [String: SlotLoad] = [:]
    @ObservationIgnored private var caching: Set<String> = []
    @ObservationIgnored private let images: any PhotoImageSource
    @ObservationIgnored private let library: any PhotoLibraryClient

    init(images: any PhotoImageSource, library: any PhotoLibraryClient) {
        self.images = images
        self.library = library
    }

    func slot(for assetID: String) -> PhotoSlot? { slots[assetID] }

    /// Loads exactly `assetIDs` (current photo first, then upcoming) and releases all others.
    func show(_ assetIDs: [String]) {
        ImageSignposts.signposter.emitEvent("Window", "\(assetIDs.first ?? "-", privacy: .public) \(assetIDs.count)")
        let wanted = Set(assetIDs)
        for id in slots.keys where !wanted.contains(id) {
            loads[id]?.cancel()
            loads[id] = nil
            slots[id] = nil
        }
        // Whether the photos in front were sharp (or done failing) before this move.
        let frontIsSettled = assetIDs.prefix(2).allSatisfy { id in
            slots[id].map { $0.isSharp || $0.didFail } == true
        }
        // Requests first, in window order, so the current photo is ahead of the prefetching.
        for (place, id) in assetIDs.enumerated() {
            let slot = slots[id] ?? makeSlot(id)
            requestSharpImage(of: slot, isNearFront: place <= 1, frontIsSettled: frontIsSettled)
            if place <= 2 {
                requestStoredPreviewIfNeeded(of: slot)
                requestPreviewIfNeeded(of: slot)
            }
        }
        let stale = caching.subtracting(wanted)
        if !stale.isEmpty {
            images.stopCachingFullImages(for: Array(stale))
            caching.subtract(stale)
        }
        // Only the photos whose request waits for the cache: one requested at once (the next
        // photo, when the window is new) would be decoded twice.
        let upcoming = assetIDs.filter { loads[$0]?.isSharpDeferred == true && !caching.contains($0) }
        if !upcoming.isEmpty {
            images.startCachingFullImages(for: upcoming)
            caching.formUnion(upcoming)
        }
    }

    /// Releases every photo (when leaving the sorting screen).
    func releaseAll() {
        show([])
    }

    // MARK: Loading

    /// A new slot, its details loading. Finished tasks stay in `loads` until the photo is
    /// released, so a stale completion can never clear the handle of a newer task.
    private func makeSlot(_ id: String) -> PhotoSlot {
        let slot = PhotoSlot(id: id)
        slots[id] = slot
        loads[id] = SlotLoad(metadata: Task { [weak self] in await self?.loadMetadata(into: slot) })
        return slot
    }

    /// Starts loading the sharp image, unless it is loading already: at once near the front or
    /// when the front is settled, otherwise after `cacheLead`. A photo that moves up to the front
    /// while it waits is requested at once; one further ahead keeps waiting for the cache.
    private func requestSharpImage(of slot: PhotoSlot, isNearFront: Bool, frontIsSettled: Bool) {
        var load = loads[slot.id] ?? SlotLoad()
        let delay: Duration
        if load.sharp != nil {
            guard load.isSharpDeferred, isNearFront else { return }
            load.sharp?.cancel()
            // Its preview, still waiting (it counts from the sharp request), counts from now.
            load.preview?.cancel()
            load.preview = nil
            delay = .zero
        } else {
            delay = isNearFront || frontIsSettled ? .zero : Self.cacheLead
        }
        load.isSharpDeferred = delay > .zero
        load.sharpDue = .now + delay
        load.sharp = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                self?.loads[slot.id]?.isSharpDeferred = false
            }
            await self?.loadSharpImage(into: slot)
        }
        loads[slot.id] = load
    }

    /// The preview the library keeps, for a photo that may reach the front before its sharp image
    /// is in: asked for at once, from a source that has stored previews.
    private func requestStoredPreviewIfNeeded(of slot: PhotoSlot) {
        guard let source = images as? any StoredPreviewSource, slot.preview == nil, !slot.isSharp,
              let load = loads[slot.id], load.storedPreview == nil else { return }
        loads[slot.id]?.storedPreview = Task {
            if let preview = await source.storedPreview(for: slot.id), !Task.isCancelled, !slot.isSharp, slot.preview == nil {
                slot.preview = preview
            }
        }
    }

    /// The quick preview decoded from the original, for a photo that may reach the front before
    /// its sharp image is in: asked for `previewLead` after the sharp image, if neither that nor a
    /// stored preview has come by then.
    private func requestPreviewIfNeeded(of slot: PhotoSlot) {
        guard slot.preview == nil, !slot.isSharp, let load = loads[slot.id], load.preview == nil else { return }
        let due = load.sharpDue + Self.previewLead
        loads[slot.id]?.preview = Task { [weak self] in
            try? await Task.sleep(until: due, clock: .continuous)
            guard !Task.isCancelled else { return }
            await self?.loadPreview(into: slot)
        }
    }

    private func loadMetadata(into slot: PhotoSlot) async {
        if let metadata = await library.metadata(for: [slot.id])[slot.id] {
            slot.metadata = metadata
        }
    }

    private func loadPreview(into slot: PhotoSlot) async {
        guard !slot.isSharp, slot.preview == nil else { return }
        if let preview = await images.preview(for: slot.id), !Task.isCancelled {
            slot.preview = preview
        }
    }

    private func loadSharpImage(into slot: PhotoSlot) async {
        let image = await images.fullImage(for: slot.id) { [weak slot] value in
            // Progress hops to the main actor on its own, so it can land after the result.
            guard let slot, slot.image == nil, !slot.didFail else { return }
            slot.downloadProgress = value
        }
        guard !Task.isCancelled else { return }
        slot.downloadProgress = nil
        if let image {
            slot.image = image
            // The previews aren't needed any more; stop them if they're still on their way.
            loads[slot.id]?.storedPreview?.cancel()
            loads[slot.id]?.preview?.cancel()
        } else {
            // The preview is all the card can show now: get it, without waiting, before the
            // failure shows (the stored one, if it is on its way, or a decoded one).
            if slot.preview == nil {
                await loads[slot.id]?.storedPreview?.value
                loads[slot.id]?.preview?.cancel()
                await loadPreview(into: slot)
                guard !Task.isCancelled else { return }
            }
            slot.didFail = true
        }
    }
}

/// The tasks loading one photo.
private struct SlotLoad {
    var metadata: Task<Void, Never>?
    var storedPreview: Task<Void, Never>?
    var preview: Task<Void, Never>?
    var sharp: Task<Void, Never>?
    /// The sharp image is waiting for the cache (`cacheLead`) and isn't requested yet.
    var isSharpDeferred = false
    /// When the sharp image is, or was, asked for.
    var sharpDue = ContinuousClock.now

    func cancel() {
        metadata?.cancel()
        storedPreview?.cancel()
        preview?.cancel()
        sharp?.cancel()
    }
}

/// An image source that can also hand over the preview the photo library keeps for a photo, a
/// stored thumbnail, without decoding the original or downloading anything. The loader asks for it
/// as soon as a photo nears the front, so a photo that isn't sharp yet shows blurred instead of
/// grey; sources without one (test doubles) only get the decoded preview, when the sharp image is
/// late.
@MainActor
protocol StoredPreviewSource: PhotoImageSource {
    /// The stored preview, or nil soon when the library has none.
    func storedPreview(for assetID: String) async -> UIImage?
}

/// Signposts for Instruments (the os_signpost instrument) and `XCTOSSignpostMetric`: subsystem
/// "io.belleville.piq", category "images". Image requests are intervals named after their kind
/// ("Thumbnail", "Stored preview", "Preview", "Full image"; the end says what was delivered, or why
/// nothing was). Events: "Launch" (the image source is created), "Cached thumbnail" (one served
/// without asking Photos), "Caching" (prefetching starts or stops),
/// "Window" (the sorting window moves) and "Card" (what the photo in front shows: placeholder,
/// blurred preview, spinner or sharp image).
enum ImageSignposts {
    static let subsystem = "io.belleville.piq"
    static let category = "images"
    static let signposter = OSSignposter(subsystem: subsystem, category: category)
}
