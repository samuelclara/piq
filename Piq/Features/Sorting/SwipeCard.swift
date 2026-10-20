import SwiftUI

/// One card in the stack and where it sits.
struct StackCard: Identifiable {
    enum Role: Equatable {
        /// The next photo, peeking out behind the current one.
        case behind
        /// The current photo, the only one that can be dragged.
        case front
        /// Flying off the stage, headed for `offset`.
        case departing(offset: CGSize)
    }

    /// The photo's asset ID: a card keeps its identity (and its view) from behind to front to
    /// gone.
    let id: String
    let role: Role
    let slot: PhotoSlot?
    /// The photo aspect-fit in the stage's box; the card behind takes the front card's size.
    let size: CGSize
}

/// A card in the stack: its pose (behind, in front, flying off), the drag that moves and tilts
/// it, and the light haptic when a swipe arms.
struct SwipeCard: View {
    /// The stage's coordinate space. Drags are measured in it, so the tilt never skews them.
    static let coordinateSpace = "SortingStage"

    let card: StackCard
    let deck: SwipeDeck

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var isTouching = false

    var body: some View {
        let offset = self.offset
        let isBehind = card.role == .behind
        let shape = RoundedRectangle(cornerRadius: Metrics.photoCorner, style: .continuous)
        PhotoCard(assetID: card.id, slot: card.slot, size: card.size, showsDetails: !isBehind)
            .overlay { SwipeOverlay(translation: offset.width) }
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
            .modifier(CardFlightEffect(offset: offset, tilts: !reduceMotion))
            .gesture(drag, including: card.role == .front ? .all : .none)
            .allowsHitTesting(card.role == .front)
            .sensoryFeedback(.impact(weight: .light), trigger: armedDirection(at: offset)) { _, armed in armed != nil }
            .onChange(of: isTouching) { _, touching in
                guard !touching else { return }
                // Runs after `onEnded` when the gesture finished normally, so only a drag that
                // was cut short springs back here.
                let id = card.id
                Task { @MainActor in deck.dragCancelled(id) }
            }
    }

    /// Where the card is, relative to its resting place. Only the front card reads the drag.
    private var offset: CGSize {
        switch card.role {
        case .behind:
            .zero
        case .front:
            deck.draggedID == card.id ? deck.dragTranslation : .zero
        case .departing(let offset):
            offset
        }
    }

    /// The side a release would send the card to, once the drag is past the threshold.
    private func armedDirection(at offset: CGSize) -> SwipeAction.Direction? {
        guard card.role == .front, abs(offset.width) >= Metrics.swipeThreshold else { return nil }
        return offset.width < 0 ? .left : .right
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.coordinateSpace))
            .updating($isTouching) { _, touching, _ in touching = true }
            .onChanged { value in deck.dragChanged(card.id, translation: value.translation) }
            .onEnded { value in deck.dragEnded(card.id, translation: value.translation) }
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
    /// Undo: the photo slides back in from the side it left, tilted the way it went.
    static func returning(from direction: SwipeAction.Direction, distance: CGFloat) -> AnyTransition {
        .modifier(
            active: CardFlightEffect(offset: CGSize(width: direction.sign * distance, height: 0)),
            identity: CardFlightEffect(offset: .zero)
        )
    }
}
