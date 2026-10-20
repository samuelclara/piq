import SwiftUI

/// On iOS 18 and later the full-screen preview zooms out of the long-pressed tile, and shrinks
/// back into it when it closes or is dragged down. Earlier systems use a plain full-screen cover
/// and the preview's own drag to dismiss.
enum ReviewPreviewZoom {
    static var isAvailable: Bool {
        if #available(iOS 18.0, *) {
            return true
        }
        return false
    }
}

extension View {
    /// Marks a tile as the place the preview of `assetID` zooms out of.
    @ViewBuilder
    func reviewZoomSource(id assetID: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            matchedTransitionSource(id: assetID, in: namespace) { source in
                source.clipShape(RoundedRectangle(cornerRadius: Metrics.thumbCorner, style: .continuous))
            }
        } else {
            self
        }
    }

    /// Zooms the preview of `assetID` out of its tile.
    @ViewBuilder
    func reviewZoomTransition(from assetID: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            navigationTransition(.zoom(sourceID: assetID, in: namespace))
        } else {
            self
        }
    }
}
