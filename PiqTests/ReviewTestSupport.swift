import SwiftUI
import XCTest
@testable import Piq

/// The mock library's images, recording the thumbnail sizes asked for, with a quick preview and a
/// sharp image that can be made to fail (an iCloud photo while offline).
@MainActor
final class StubImageSource: PhotoImageSource {
    var failsPreview = false
    var failsFullImage = false
    /// Edge lengths (points) of the thumbnails requested, by asset.
    private(set) var thumbnailSides: [String: [CGFloat]] = [:]
    private let base: any PhotoImageSource

    init(base: any PhotoImageSource) {
        self.base = base
    }

    func thumbnail(for assetID: String, pointSize: CGSize, scale: CGFloat) async -> UIImage? {
        thumbnailSides[assetID, default: []].append(pointSize.width)
        return await base.thumbnail(for: assetID, pointSize: pointSize, scale: scale)
    }

    func preview(for assetID: String) async -> UIImage? {
        failsPreview ? nil : await base.preview(for: assetID)
    }

    func fullImage(for assetID: String, progress: @escaping @MainActor @Sendable (Double) -> Void) async -> UIImage? {
        guard failsFullImage else { return await base.fullImage(for: assetID, progress: progress) }
        progress(0.4)
        try? await Task.sleep(for: .milliseconds(150))
        return nil
    }

    func startCachingFullImages(for assetIDs: [String]) {}

    func stopCachingFullImages(for assetIDs: [String]) {}
}

extension AppModel {
    /// An app model over the same mock library as `base` (so its sessions apply), loading images
    /// through `images`.
    static func reviewTest(sharingLibraryOf base: AppModel, images: any PhotoImageSource) -> AppModel {
        AppModel(library: base.library, images: images, container: PreviewSupport.inMemoryContainer())
    }
}

/// A visible window of `width` × `height` points in the test host's scene, showing `content`.
@MainActor
func makeReviewTestWindow<Content: View>(width: CGFloat, height: CGFloat = 834, @ViewBuilder content: () -> Content) throws -> UIWindow {
    guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
        throw XCTSkip("No window scene to render into")
    }
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: width, height: height)
    window.rootViewController = UIHostingController(rootView: content())
    window.isHidden = false
    return window
}
