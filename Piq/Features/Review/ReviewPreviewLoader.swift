import Observation
import UIKit

/// Loads the photo in the full-screen preview: its details, the quick preview, then the sharp
/// image (through a `PhotoWindowLoader`). After the sharp image fails, `retry()` loads it again
/// while the quick preview stays on screen.
@MainActor
@Observable
final class ReviewPreviewLoader {
    let assetID: String
    /// The quick preview of an attempt that failed, kept while a retry loads its own.
    private(set) var earlierPreview: UIImage?
    @ObservationIgnored private let loader: PhotoWindowLoader

    init(assetID: String, images: any PhotoImageSource, library: any PhotoLibraryClient) {
        self.assetID = assetID
        self.loader = PhotoWindowLoader(images: images, library: library)
    }

    var slot: PhotoSlot? { loader.slot(for: assetID) }

    /// The blurry-first image: this attempt's quick preview, or the failed attempt's.
    var quickPreview: UIImage? { slot?.preview ?? earlierPreview }

    /// The sharp image couldn't be loaded.
    var didFail: Bool { slot?.didFail == true }

    /// Starts loading, unless the photo is loaded or on its way.
    func start() {
        loader.show([assetID])
    }

    func retry() {
        earlierPreview = quickPreview
        loader.releaseAll()
        loader.show([assetID])
    }

    func release() {
        loader.releaseAll()
    }
}
