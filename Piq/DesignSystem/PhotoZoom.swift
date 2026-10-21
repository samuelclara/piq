import SwiftUI

/// Pinch-to-zoom on a photo: how much it is magnified and where it has been moved, and the
/// arithmetic of the gestures that change them (pinch, one-finger pan while zoomed, double-tap).
///
/// The photo is drawn at `content` size, centered in a `viewport` (the sorting card, or the
/// preview's screen), then scaled around the viewport's center and moved by `offset`. Points are
/// given relative to the viewport's center, so a point `p` of the unzoomed photo shows at
/// `p * scale + offset`. Pinching keeps the point under the fingers still; past the limits
/// (1× and `maxScale`, or the photo's edges) the photo follows the fingers with resistance and
/// settles back when they lift.
struct PhotoZoom: Equatable {
    /// How far a pinch can magnify the photo.
    static let maxScale: CGFloat = 5
    /// Where a double-tap zooms in to.
    static let doubleTapScale: CGFloat = 2.5
    /// From this magnification on, the photo is shown from a sharper image than the screen-sized
    /// one (see `PhotoImageSource.zoomImage(for:)`).
    static let detailScale: CGFloat = 1.2

    private(set) var scale: CGFloat = 1
    private(set) var offset: CGSize = .zero

    /// Where the pinch in progress started: the scale and offset then, and the point between the
    /// fingers.
    private var pinchStart: (scale: CGFloat, offset: CGSize, anchor: CGPoint)?
    /// The offset when the pan in progress started, and the translation it was measured from.
    private var panStart: (offset: CGSize, translation: CGSize)?

    /// Zoomed in far enough that one finger moves the photo instead of swiping it.
    var isZoomed: Bool { scale > 1.01 }

    /// Whether to show the sharper image.
    var wantsDetail: Bool { scale >= Self.detailScale }

    var isPinching: Bool { pinchStart != nil }

    static func == (lhs: PhotoZoom, rhs: PhotoZoom) -> Bool {
        lhs.scale == rhs.scale && lhs.offset == rhs.offset && lhs.isPinching == rhs.isPinching
    }

    // MARK: Pinch

    /// `magnification` is relative to the pinch's start; `anchor` is where it started.
    mutating func pinchChanged(magnification: CGFloat, anchor: CGPoint) {
        if pinchStart == nil {
            pinchStart = (scale, offset, anchor)
            panStart = nil
        }
        guard let start = pinchStart, magnification > 0 else { return }
        let newScale = Self.resisted(start.scale * magnification, in: 1...Self.maxScale)
        scale = newScale
        offset = Self.offset(keeping: start.anchor, from: start.offset, scale: start.scale, to: newScale)
    }

    /// Settles a pinch back within 1×…`maxScale` and the photo's edges.
    mutating func pinchEnded(content: CGSize, viewport: CGSize) {
        guard let start = pinchStart else { return }
        pinchStart = nil
        let settled = min(max(scale, 1), Self.maxScale)
        if settled <= 1.01 {
            reset()
            return
        }
        let moved = Self.offset(keeping: start.anchor, from: start.offset, scale: start.scale, to: settled)
        scale = settled
        offset = Self.clamped(moved, scale: settled, content: content, viewport: viewport)
    }

    // MARK: Pan

    /// One finger moving the zoomed photo. `translation` is the drag's, from wherever it started:
    /// a pan that begins partway through a drag (once a pinch lets go) starts from there.
    mutating func panChanged(translation: CGSize, content: CGSize, viewport: CGSize) {
        guard isZoomed, !isPinching else { return }
        if panStart == nil {
            panStart = (offset, translation)
        }
        guard let start = panStart else { return }
        let wanted = CGSize(
            width: start.offset.width + translation.width - start.translation.width,
            height: start.offset.height + translation.height - start.translation.height
        )
        let limits = Self.limits(scale: scale, content: content, viewport: viewport)
        offset = CGSize(
            width: Self.resisted(wanted.width, in: -limits.width...limits.width),
            height: Self.resisted(wanted.height, in: -limits.height...limits.height)
        )
    }

    /// Lets go of the photo: it glides a little in the direction it was flicked, and stays within
    /// its edges. `predictedTranslation` is the drag's predicted end.
    mutating func panEnded(translation: CGSize, predictedTranslation: CGSize, content: CGSize, viewport: CGSize) {
        guard panStart != nil else { return }
        panStart = nil
        let glide = CGSize(
            width: (predictedTranslation.width - translation.width) * 0.5,
            height: (predictedTranslation.height - translation.height) * 0.5
        )
        let target = CGSize(width: offset.width + glide.width, height: offset.height + glide.height)
        offset = Self.clamped(target, scale: scale, content: content, viewport: viewport)
    }

    /// The touch went away mid-gesture: whatever was under way settles where it is.
    mutating func gestureCancelled(content: CGSize, viewport: CGSize) {
        if isPinching {
            pinchEnded(content: content, viewport: viewport)
        }
        if panStart != nil {
            panStart = nil
            offset = Self.clamped(offset, scale: scale, content: content, viewport: viewport)
        }
    }

    // MARK: Double-tap and reset

    /// Zoomed in: back to the whole photo. Otherwise in to `doubleTapScale`, around `point`.
    mutating func toggle(at point: CGPoint, content: CGSize, viewport: CGSize) {
        if isZoomed {
            reset()
            return
        }
        pinchStart = nil
        panStart = nil
        let target = Self.doubleTapScale
        scale = target
        offset = Self.clamped(Self.offset(keeping: point, from: .zero, scale: 1, to: target), scale: target, content: content, viewport: viewport)
    }

    mutating func reset() {
        scale = 1
        offset = .zero
        pinchStart = nil
        panStart = nil
    }

    // MARK: Geometry

    /// How far the photo can move from the center each way at `scale`: until its edges meet the
    /// viewport's, or not at all along a side where it is narrower than the viewport.
    static func limits(scale: CGFloat, content: CGSize, viewport: CGSize) -> CGSize {
        CGSize(
            width: max(0, (content.width * scale - viewport.width) / 2),
            height: max(0, (content.height * scale - viewport.height) / 2)
        )
    }

    static func clamped(_ offset: CGSize, scale: CGFloat, content: CGSize, viewport: CGSize) -> CGSize {
        let limits = limits(scale: scale, content: content, viewport: viewport)
        return CGSize(
            width: min(max(offset.width, -limits.width), limits.width),
            height: min(max(offset.height, -limits.height), limits.height)
        )
    }

    /// The offset at `newScale` that keeps the photo's point under `anchor` where it was at
    /// `oldScale` and `oldOffset`.
    static func offset(keeping anchor: CGPoint, from oldOffset: CGSize, scale oldScale: CGFloat, to newScale: CGFloat) -> CGSize {
        let ratio = newScale / oldScale
        return CGSize(
            width: anchor.x - (anchor.x - oldOffset.width) * ratio,
            height: anchor.y - (anchor.y - oldOffset.height) * ratio
        )
    }

    /// `value` within `range`; beyond it, a third of the excess, as a scroll view's edge gives.
    static func resisted(_ value: CGFloat, in range: ClosedRange<CGFloat>) -> CGFloat {
        if value < range.lowerBound {
            return range.lowerBound - (range.lowerBound - value) / 3
        }
        if value > range.upperBound {
            return range.upperBound + (value - range.upperBound) / 3
        }
        return value
    }
}

extension View {
    /// Draws the photo magnified and moved as `zoom` says, around the center.
    func photoZoom(_ zoom: PhotoZoom) -> some View {
        scaleEffect(zoom.scale).offset(zoom.offset)
    }
}

/// The sharper image of a zoomed photo, over the screen-sized one: loaded once the photo is
/// magnified past `PhotoZoom.detailScale`, and let go when it is zoomed back out or the view goes.
/// Until it arrives, the screen-sized image shows magnified.
struct ZoomDetailImage: View {
    let assetID: String
    let isWanted: Bool

    @Environment(AppModel.self) private var app
    @State private var image: UIImage?
    /// The photo `image` is of.
    @State private var imageID: String?

    var body: some View {
        ZStack {
            if let image, imageID == assetID {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: image != nil)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: LoadKey(assetID: assetID, isWanted: isWanted)) {
            guard isWanted else {
                image = nil
                imageID = nil
                return
            }
            guard image == nil || imageID != assetID else { return }
            image = nil
            let loaded = await app.images.zoomImage(for: assetID)
            if !Task.isCancelled {
                image = loaded
                imageID = assetID
            }
        }
    }

    private struct LoadKey: Equatable {
        let assetID: String
        let isWanted: Bool
    }
}
