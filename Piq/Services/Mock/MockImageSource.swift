#if DEBUG
import UIKit

/// Serves the mock library's photos from Preview Assets. `fullImageLatency` simulates an iCloud
/// download (with progress) so the blurry-preview-then-sharp swap and the spinner can be seen.
/// Like a device's library, it keeps a preview of every photo, handed over at once.
@MainActor
final class MockImageSource: StoredPreviewSource {
    private let library: MockPhotoLibrary
    var fullImageLatency: Duration

    init(library: MockPhotoLibrary, fullImageLatency: Duration = .zero) {
        self.library = library
        self.fullImageLatency = fullImageLatency
    }

    func thumbnail(for assetID: String, pointSize: CGSize, scale: CGFloat) async -> UIImage? {
        guard let image = baseImage(for: assetID) else { return nil }
        let target = CGSize(width: pointSize.width * scale, height: pointSize.height * scale)
        let fill = max(target.width / image.size.width, target.height / image.size.height)
        let size = CGSize(width: (image.size.width * fill).rounded(.up), height: (image.size.height * fill).rounded(.up))
        return image.preparingThumbnail(of: size) ?? image
    }

    func preview(for assetID: String) async -> UIImage? {
        guard let image = baseImage(for: assetID) else { return nil }
        // Tiny on purpose: scaled up, it reads as the blurry placeholder.
        let width: CGFloat = 48
        return image.preparingThumbnail(of: CGSize(width: width, height: (width * image.size.height / image.size.width).rounded()))
    }

    func storedPreview(for assetID: String) async -> UIImage? {
        await preview(for: assetID)
    }

    func fullImage(for assetID: String, progress: @escaping @MainActor @Sendable (Double) -> Void) async -> UIImage? {
        if fullImageLatency > .zero {
            let steps = 5
            for step in 1...steps {
                try? await Task.sleep(for: fullImageLatency / steps)
                if Task.isCancelled { return nil }
                progress(Double(step) / Double(steps))
            }
        }
        return baseImage(for: assetID)
    }

    func startCachingFullImages(for assetIDs: [String]) {}

    func stopCachingFullImages(for assetIDs: [String]) {}

    private func baseImage(for assetID: String) -> UIImage? {
        library.imageName(for: assetID).flatMap { UIImage(named: $0) }
    }
}
#endif
