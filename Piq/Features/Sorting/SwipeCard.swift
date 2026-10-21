import SwiftUI

/// One card in the stack and where it sits.
struct StackCard: Identifiable {
    enum Role: Equatable {
        /// The next photo, peeking out behind the current one.
        case behind
        /// The current photo, the only one that can be dragged.
        case front
        /// Leaving the stage, headed for `offset`: flying off with a decision (tilted and tinted
        /// like a swipe), or, when `decides` is false, sliding off flat because Next moved on.
        case departing(offset: CGSize, decides: Bool)
    }

    /// The photo's asset ID: a card keeps its identity (and its view) from behind to front to
    /// gone.
    let id: String
    let role: Role
    let slot: PhotoSlot?
    /// The photo aspect-fit in the stage's box; the card behind takes the front card's size.
    let size: CGSize
    /// The front card's decision, shown as a tag when the person comes back to a decided photo.
    var verdict: Verdict?
}

/// A card in the stack: its pose (behind, in front, flying off), the drag that moves and tilts
/// it, and the light haptic when a swipe arms. The card in front also zooms: pinch, or double-tap
/// in and out. While it is zoomed in, one finger moves the photo inside the card instead of
/// swiping it; the buttons and the arrow keys still decide.
struct SwipeCard: View {
    /// The stage's coordinate space. Drags are measured in it, so the tilt never skews them.
    static let coordinateSpace = "SortingStage"

    let card: StackCard
    let deck: SwipeDeck

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var isTouching = false
    @State private var zoom = PhotoZoom()
    /// What the finger on the card is doing, decided when it starts moving.
    @State private var dragMode: DragMode?

    private enum DragMode {
        /// Dragging the card toward a decision.
        case swipe
        /// Moving the zoomed photo inside the card.
        case pan
        /// One of a pinch's fingers: the pinch handles it.
        case ignored
    }

    var body: some View {
        let offset = self.offset
        let isBehind = card.role == .behind
        let swipes = self.swipes
        let shape = RoundedRectangle(cornerRadius: Metrics.photoCorner, style: .continuous)
        let isFront = card.role == .front
        PhotoCard(assetID: card.id, slot: card.slot, size: card.size, showsDetails: !isBehind, verdict: card.verdict, zoom: zoom)
            .overlay { SwipeOverlay(translation: swipes ? offset.width : 0) }
            .clipShape(shape)
            .background {
                shape
                    .fill(Palette.raised)
                    .shadow(color: .black.opacity(isBehind ? 0 : 0.55), radius: 34, y: 22)
            }
            .scaleEffect(isBehind ? Metrics.stackScale : 1, anchor: .bottom)
            .offset(y: isBehind ? Metrics.stackOffset : 0)
            .opacity(isBehind ? Metrics.stackOpacity : 1)
            // Moving up to the front (or back, on Undo) springs, whatever else is animating.
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.82), value: isBehind)
            .modifier(CardFlightEffect(offset: offset, tilts: swipes && !reduceMotion))
            .gesture(drag, including: isFront ? .all : .none)
            .simultaneousGesture(pinch, including: isFront ? .all : .none)
            .simultaneousGesture(doubleTap, including: isFront ? .all : .none)
            .allowsHitTesting(isFront)
            .sensoryFeedback(.impact(weight: .light), trigger: armedDirection(at: offset)) { _, armed in armed != nil }
            .onChange(of: isTouching) { _, touching in
                guard !touching else { return }
                // Runs after `onEnded` when the gesture finished normally, so only a drag that
                // was cut short springs back (or settles the zoomed photo) here.
                dragMode = nil
                withAnimation(settle) { zoom.gestureCancelled(content: card.size, viewport: card.size) }
                let id = card.id
                Task { @MainActor in deck.dragCancelled(id) }
            }
            .onChange(of: isFront && zoom.isZoomed, initial: true) { _, isZoomed in
                if isFront {
                    deck.setZoomed(isZoomed, photo: card.id)
                }
            }
    }

    /// Where the card is, relative to its resting place. Only the front card reads the drag.
    private var offset: CGSize {
        switch card.role {
        case .behind:
            .zero
        case .front:
            deck.draggedID == card.id ? deck.dragTranslation : .zero
        case .departing(let offset, _):
            offset
        }
    }

    /// Whether the card moves as a swipe does, tilted and tinted: not when Next slides it off.
    private var swipes: Bool {
        if case .departing(_, let decides) = card.role {
            return decides
        }
        return true
    }

    /// The side a release would send the card to, once the drag is past the threshold.
    private func armedDirection(at offset: CGSize) -> SwipeAction.Direction? {
        guard card.role == .front, abs(offset.width) >= Metrics.swipeThreshold else { return nil }
        return offset.width < 0 ? .left : .right
    }

    /// A swipe, or a pan of the zoomed photo.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.coordinateSpace))
            .updating($isTouching) { _, touching, _ in touching = true }
            .onChanged { value in
                if dragMode == nil {
                    dragMode = zoom.isPinching ? .ignored : zoom.isZoomed ? .pan : .swipe
                }
                switch dragMode {
                case .swipe: deck.dragChanged(card.id, translation: value.translation)
                case .pan: zoom.panChanged(translation: value.translation, content: card.size, viewport: card.size)
                case .ignored, nil: break
                }
            }
            .onEnded { value in
                switch dragMode {
                case .swipe:
                    deck.dragEnded(card.id, translation: value.translation)
                case .pan:
                    withAnimation(settle) {
                        zoom.panEnded(translation: value.translation, predictedTranslation: value.predictedEndTranslation, content: card.size, viewport: card.size)
                    }
                case .ignored, nil:
                    break
                }
                dragMode = nil
            }
    }

    /// Zooms around the point between the fingers. A swipe under way when the second finger
    /// lands springs back; once the pinch ends, a finger still down moves the photo if it is
    /// zoomed in, and does nothing otherwise until it lifts.
    private var pinch: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                if dragMode == .swipe {
                    deck.dragCancelled(card.id)
                }
                if isTouching {
                    dragMode = .ignored
                }
                zoom.pinchChanged(magnification: value.magnification, anchor: centered(value.startLocation))
            }
            .onEnded { _ in
                withAnimation(settle) { zoom.pinchEnded(content: card.size, viewport: card.size) }
                dragMode = isTouching ? (zoom.isZoomed ? .pan : .ignored) : nil
            }
    }

    /// In to `PhotoZoom.doubleTapScale` around the tap, or back to the whole photo.
    private var doubleTap: some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { value in
                withAnimation(settle) { zoom.toggle(at: centered(value.location), content: card.size, viewport: card.size) }
            }
    }

    /// A point in the card, relative to its center.
    private func centered(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - card.size.width / 2, y: point.y - card.size.height / 2)
    }

    private var settle: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.86)
    }
}

/// Moves a card away from its resting place and tilts it like a swipe does: rotation is the
/// horizontal distance / 28 degrees, around the middle of its bottom edge.
struct CardFlightEffect: ViewModifier {
    let offset: CGSize
    var tilts = true

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(tilts ? offset.width / Metrics.tiltDivisor : 0), anchor: .bottom)
            .offset(offset)
    }
}

extension AnyTransition {
    /// Undo: the photo slides back in from the side it left, tilted the way it went. Previous:
    /// the photo slides in flat (`tilts` false), as nothing is decided.
    static func returning(from direction: SwipeAction.Direction, distance: CGFloat, tilts: Bool = true) -> AnyTransition {
        .modifier(
            active: CardFlightEffect(offset: CGSize(width: direction.sign * distance, height: 0), tilts: tilts),
            identity: CardFlightEffect(offset: .zero, tilts: tilts)
        )
    }
}
