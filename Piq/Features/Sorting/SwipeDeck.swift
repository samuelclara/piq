import Observation
import SwiftUI

/// The sorting screen's stack of photo cards: the drag of the front card, the cards flying off
/// the stage, the moment each decision reaches the session, and the moves of Previous and Next.
///
/// A decision commits as soon as its card has flown off the stage. If another input arrives
/// first (a button, an arrow key, a new drag, Undo, Previous or Next), the flight in progress is
/// settled right away, so no input is dropped and no photo is ever decided twice. The card keeps
/// flying either way. A move decides nothing: the session moves at once, and the card it leaves
/// slides off flat and untinted, so it never reads as a swipe.
@MainActor
@Observable
final class SwipeDeck {
    /// A card on its way off the stage.
    struct Departure: Identifiable {
        /// The photo's asset ID.
        let id: String
        /// The decision it carries; nil for a card that Next moved on from.
        let action: SwipeAction?
        /// Where the card is headed, relative to its resting place.
        var offset: CGSize
        /// The card's images, kept while it flies even though the loader has moved on.
        let slot: PhotoSlot?
        /// Whether the session has the decision yet.
        var isCommitted = false
        /// Tells two flights of the same photo apart (it can fly, come back on Undo, fly again).
        let flight: Int
    }

    /// The photo sliding back in after an undo or Previous, and the side it comes back from.
    struct Return: Equatable {
        let id: String
        let direction: SwipeAction.Direction
        /// Tilted as a swipe would (Undo), or flat (Previous, which decides nothing).
        var tilts = true
    }

    /// How long a card takes to clear the stage, plus a frame for its animation to start.
    private static let flightTime: Duration = .seconds(Metrics.flyOffDuration) + .milliseconds(17)

    let session: SessionController
    let loader: PhotoWindowLoader

    /// The card under the finger.
    private(set) var draggedID: String?
    /// How far the finger has moved that card. Only the front card reads it, so a drag redraws
    /// one card per frame and nothing else.
    private(set) var dragTranslation: CGSize = .zero
    /// Cards flying off, oldest first.
    private(set) var departures: [Departure] = []
    /// Set by an undo so the photo that comes back slides in from the side it left, and by
    /// Previous so the earlier photo slides in from the left.
    private(set) var returning: Return?
    /// The images of the photo that left the front last (decided, or moved on from with Next), so
    /// Undo or Previous brings it back sharp while the loader fetches it again. One photo at most:
    /// replaced by the next one to leave, except that Next leaves the photo Undo returns to in
    /// place (see `keepsUndoTarget`), and let go once the loader has the photo sharp again or the
    /// screen goes away.
    private(set) var lastDeparted: PhotoSlot?

    /// Mirrors the Reduce Motion setting: no flights, decisions commit with a quick crossfade.
    @ObservationIgnored var reduceMotion = false
    @ObservationIgnored private let app: AppModel
    @ObservationIgnored private var stageSize: CGSize = .zero
    @ObservationIgnored private var boxSize: CGSize = .zero
    @ObservationIgnored private var flightCount = 0
    /// Whether the screen is up. While it is away (Review on top), the deck loads no images.
    @ObservationIgnored private var isShowing = false

    init(session: SessionController, app: AppModel) {
        self.session = session
        self.app = app
        self.loader = PhotoWindowLoader(images: app.images, library: app.library)
    }

    // MARK: Lifecycle

    /// The screen is up: loads the current photo and the next ones.
    func appear() {
        isShowing = true
        show(session.state.window(lookahead: PhotoWindowLoader.lookahead))
    }

    /// Loads `window` (the current photo and the next ones) and releases every other photo.
    func show(_ window: [String]) {
        guard isShowing else { return }
        loader.show(window)
    }

    /// The screen is gone (Review on top, or back to the albums): settles everything and lets
    /// go of every image, including the flying cards' and the one kept for Undo.
    func disappear() {
        isShowing = false
        finish()
        departures.removeAll()
        loader.releaseAll()
    }

    // MARK: Reading

    /// The flight whose decision hasn't reached the session yet. There is at most one: any new
    /// input commits it first.
    var pendingDeparture: Departure? {
        departures.first { !$0.isCommitted }
    }

    /// Whether Undo has something to take back: a decision, or a card still in the air.
    var canUndo: Bool {
        session.state.canUndo || pendingDeparture != nil
    }

    /// Whether Previous has a photo to go back to (a card in the air counts: it lands first).
    var canGoBack: Bool {
        session.state.canGoBack || pendingDeparture != nil
    }

    /// Whether Next has a photo to move on from (on the last one, Next goes on to Review).
    var canGoForward: Bool {
        session.state.canGoForward
    }

    /// The photo in front of the stack and the one behind it. As soon as a card starts flying
    /// off, the next photo moves to the front.
    var stack: (front: String?, behind: String?) {
        var ids = session.state.window(lookahead: 2)
        if let pending = pendingDeparture, ids.first == pending.id {
            ids.removeFirst()
        }
        return (ids.first, ids.dropFirst().first)
    }

    /// The images for a card. A flying card keeps its own; a photo coming back on Undo shows the
    /// ones it left with until the loader has its sharp image again.
    func slot(for id: String) -> PhotoSlot? {
        if let departure = departures.first(where: { $0.id == id }) {
            return departure.slot
        }
        let live = loader.slot(for: id)
        if let kept = lastDeparted, kept.id == id, live?.isSharp != true {
            return kept
        }
        return live
    }

    /// The details of `id` for VoiceOver: the loader's, or, for a photo that has only just come
    /// into the window (Previous lands on one the loader had let go), the library's at once
    /// rather than whenever the loader gets to them.
    func metadata(for id: String) async -> PhotoMetadata? {
        if let metadata = slot(for: id)?.metadata {
            return metadata
        }
        return await app.library.metadata(for: [id])[id]
    }

    /// Whether the loader has loaded the photo kept for Undo again, sharp (it came back), so the
    /// kept images are a second copy. Right after the decision the loader may still hold the
    /// very same slot, which doesn't count.
    var hasReloadedLastDeparted: Bool {
        guard let kept = lastDeparted, let live = loader.slot(for: kept.id) else { return false }
        return live !== kept && live.isSharp
    }

    /// Lets go of the images kept for Undo once the loader has that photo again.
    func releaseLastDeparted() {
        guard hasReloadedLastDeparted else { return }
        lastDeparted = nil
    }

    /// How far a card travels to leave the stage completely, shadow and tilt included.
    var flightDistance: CGFloat {
        stageSize.width / 2 + boxSize.width / 2 + 80
    }

    /// The stage reports its size so flights know how far to go.
    func setStage(_ size: CGSize, box: CGSize) {
        stageSize = size
        boxSize = box
    }

    // MARK: Dragging

    func dragChanged(_ id: String, translation: CGSize) {
        if draggedID != id {
            // A new drag: a card still in the air is decided now, so this one is current.
            commitPending()
            guard id == session.state.currentAssetID else { return }
            draggedID = id
            returning = nil
        }
        dragTranslation = translation
    }

    /// Past the threshold the card flies off that side; short of it, it springs back.
    func dragEnded(_ id: String, translation: CGSize) {
        guard draggedID == id else { return }
        if abs(translation.width) >= Metrics.swipeThreshold {
            let action = SwipeAction.action(for: translation.width < 0 ? .left : .right)
            send(id, action, from: translation)
        } else {
            springBack()
        }
    }

    /// The touch went away without ending the gesture (the system took it, the card left the
    /// screen). Harmless after `dragEnded`.
    func dragCancelled(_ id: String) {
        guard draggedID == id else { return }
        springBack()
    }

    private func springBack() {
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.7)) {
            draggedID = nil
            dragTranslation = .zero
        }
    }

    // MARK: Deciding

    /// Decides the current photo: the card flies off toward `action`'s side and the decision
    /// commits once it's gone (right away, with a crossfade, under Reduce Motion).
    func decide(_ action: SwipeAction) {
        commitPending()
        guard let id = session.state.currentAssetID else { return }
        send(id, action, from: draggedID == id ? dragTranslation : .zero)
    }

    /// Decides the current photo right away, without the flight (VoiceOver actions).
    func decideNow(_ action: SwipeAction) {
        commitPending()
        guard let id = session.state.currentAssetID else { return }
        crossfade(id, action)
    }

    /// Takes back the last decision. A card still in the air turns around; otherwise the
    /// session steps back and the photo slides in from the side it left.
    func undo() {
        let animation: Animation = reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.8)
        if let index = departures.firstIndex(where: { !$0.isCommitted }) {
            withAnimation(animation) {
                endDrag()
                departures.remove(at: index)
            }
            return
        }
        guard session.state.canUndo else { return }
        withAnimation(animation) {
            endDrag()
            guard let decision = session.undo() else { return }
            if let index = departures.firstIndex(where: { $0.id == decision.assetID }) {
                departures.remove(at: index)
                returning = nil
            } else {
                returning = Return(id: decision.assetID, direction: decision.action.direction)
            }
            withdrawConfirmation(of: decision)
        }
    }

    /// Previous or Next: the session moves without deciding anything. The card on screen slides
    /// off flat toward the side the move goes (Next sends it left, as the next photo comes up
    /// from behind; Previous brings the earlier photo in from the left, over it), with a
    /// crossfade under Reduce Motion. Next past the last photo goes on to Review, as the last
    /// decision does.
    func step(_ step: PhotoStep) {
        commitPending()
        guard isOnTop else { return }
        let state = session.state
        let leaving = state.currentAssetID
        let leavingSlot = leaving.flatMap { slot(for: $0) }
        let animation: Animation = reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.38, dampingFraction: 0.86)
        flightCount += 1
        let flight = flightCount
        var moved = false
        withAnimation(animation) {
            endDrag()
            guard session.step(step) else { return }
            moved = true
            let arriving = session.state.currentAssetID
            if let arriving, let index = departures.firstIndex(where: { $0.id == arriving }) {
                // Back before it finished sliding off: the same card slides back.
                departures.remove(at: index)
                returning = nil
            } else if step == .previous, let arriving {
                returning = Return(id: arriving, direction: .left, tilts: false)
            } else {
                returning = nil
            }
            if step == .next, let leaving, !reduceMotion {
                let offset = CGSize(width: -flightDistance, height: 0)
                departures.append(Departure(id: leaving, action: nil, offset: offset, slot: leavingSlot, isCommitted: true, flight: flight))
            }
        } completion: { [weak self] in
            // Off the stage by now.
            self?.departures.removeAll { $0.flight == flight }
        }
        guard moved else { return }
        if step == .next, let leavingSlot, !keepsUndoTarget(over: leavingSlot) {
            lastDeparted = leavingSlot
        }
        if session.state.currentAssetID == nil {
            app.showReview()
        }
    }

    /// Commits the card in flight now (the card keeps flying).
    func commitPending() {
        guard let index = departures.firstIndex(where: { !$0.isCommitted }) else { return }
        commitFlight(at: index)
    }

    /// The session's current photo changed underneath the deck (a library change): a drag on
    /// another photo is over.
    func currentPhotoChanged(to id: String?) {
        guard draggedID != nil, draggedID != id else { return }
        endDrag()
    }

    /// Settles everything before the screen goes away: the card in the air is decided, a drag
    /// ends, and the images kept for Undo are let go.
    func finish() {
        commitPending()
        endDrag()
        lastDeparted = nil
    }

    // MARK: Private

    private func send(_ id: String, _ action: SwipeAction, from start: CGSize) {
        returning = nil
        guard !reduceMotion else {
            crossfade(id, action)
            return
        }
        flightCount += 1
        let flight = flightCount
        let departure = Departure(id: id, action: action, offset: flightTarget(from: start, toward: action.direction), slot: slot(for: id), flight: flight)
        withAnimation(.easeIn(duration: Metrics.flyOffDuration)) {
            endDrag()
            departures.append(departure)
        } completion: { [weak self] in
            // This waits for the next card to settle in front too; the departed card has long
            // been off screen.
            self?.remove(flight)
        }
        // The decision lands as the card clears the stage, not once the next card has settled.
        Task { [weak self] in
            try? await Task.sleep(for: Self.flightTime)
            self?.land(flight)
        }
    }

    /// Commits in place: the card fades out where it is and the next one fades up.
    private func crossfade(_ id: String, _ action: SwipeAction) {
        returning = nil
        let slot = slot(for: id)
        withAnimation(.easeInOut(duration: 0.2)) {
            endDrag()
            commit(id, action, slot: slot)
        }
    }

    /// A card has left the stage: its decision commits, unless another input already did.
    private func land(_ flight: Int) {
        guard let index = departures.firstIndex(where: { $0.flight == flight }) else { return }
        commitFlight(at: index)
    }

    /// The flight's animations are over: the card, off screen, goes away. Its decision is in by
    /// now, unless nothing animated (the screen was covered), in which case it commits here.
    private func remove(_ flight: Int) {
        land(flight)
        departures.removeAll { $0.flight == flight }
    }

    private func commitFlight(at index: Int) {
        guard !departures[index].isCommitted else { return }
        departures[index].isCommitted = true
        let departure = departures[index]
        guard let action = departure.action else { return }
        commit(departure.id, action, slot: departure.slot)
    }

    private func commit(_ id: String, _ action: SwipeAction, slot: PhotoSlot?) {
        // Decide the photo that flew, so a library change underneath can't misapply it.
        guard let decision = session.decide(action, for: id) else { return }
        lastDeparted = slot
        // The toast and the move to Review belong to the sorting screen. A card that lands after
        // the app closed the screen (Photos access lost, the album gone) still counts, quietly:
        // it mustn't cover the app's explanation or open Review over the albums.
        guard isOnTop else { return }
        if let message = decision.action.confirmationMessage {
            app.toasts.show(message)
        }
        // Every photo decided, or past the last one with some skipped: Review says what is left.
        if session.state.isComplete || session.state.currentAssetID == nil {
            app.showReview()
        }
    }

    /// Whether the kept images are those of the photo Undo would bring back, which Next then
    /// leaves in place rather than keep `leaving`'s: a decision followed by Next still undoes
    /// sharp (as before Previous and Next existed), while Previous back to the photo Next left
    /// loads it again, from the library's stored preview first. Once Undo or Previous has brought
    /// the kept photo back and the loader has it, the slot is free again.
    private func keepsUndoTarget(over leaving: PhotoSlot) -> Bool {
        guard let kept = lastDeparted, kept.id != leaving.id else { return false }
        return kept.id == session.state.lastDecision?.assetID
    }

    /// Whether the sorting screen is the top screen.
    private var isOnTop: Bool {
        app.path.last == .sorting(albumID: session.albumID)
    }

    /// Takes down the toast that confirmed `decision` ("Marked for deletion") once Undo has
    /// reversed it.
    private func withdrawConfirmation(of decision: SortDecision) {
        guard let message = decision.action.confirmationMessage,
              let toast = app.toasts.current, toast.message == message else { return }
        app.toasts.dismiss(toast.id)
    }

    private func endDrag() {
        draggedID = nil
        dragTranslation = .zero
    }

    /// Fully off the stage on `direction`'s side. A thrown card keeps heading the way the finger
    /// moved it.
    private func flightTarget(from start: CGSize, toward direction: SwipeAction.Direction) -> CGSize {
        let x = direction.sign * max(flightDistance, abs(start.width))
        let ratio = abs(start.width) >= Metrics.swipeThreshold ? abs(x / start.width) : 1
        let limit = stageSize.height * 0.6
        return CGSize(width: x, height: min(max(start.height * ratio, -limit), limit))
    }

    #if DEBUG
    /// Holds the current card mid-swipe, for previews.
    func holdDrag(_ translation: CGSize) {
        draggedID = session.state.currentAssetID
        dragTranslation = translation
    }
    #endif
}
