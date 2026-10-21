import Accessibility
import SwiftUI

/// The middle of the sorting screen: the current photo as large as it fits, the next one peeking
/// out behind it, and any cards still flying off. VoiceOver, Full Keyboard Access and the keyboard
/// see one element, the current photo at rest (see `photoElement`), with an action per
/// `SwipeAction` and Previous and Next photo; the cards themselves are hidden from them.
struct SortingStage: View {
    /// The keys of the swipe actions (← and →).
    private static let actionKeys = Set(SwipeAction.allCases.map(\.keyEquivalent))

    let deck: SwipeDeck
    /// Keyboard focus. The photo holds it while sorting is on top: once arrow keys have moved
    /// the keyboard focus (on Review, say), iPadOS gives them to focus movement before keyboard
    /// shortcuts, and the first ← or → back here would be lost. Holding it on the photo, which
    /// VoiceOver and Full Keyboard Access already know, keeps the screen free of invisible stops.
    var keyFocus: FocusState<Bool>.Binding
    /// Handles ← and → while the photo has the keyboard focus (the pills' shortcuts cover the
    /// moments it doesn't). It gets the repeats of a held key too, so it can swallow them.
    let onKeyPress: (KeyPress) -> KeyPress.Result
    /// Runs a VoiceOver action: it commits without the flight.
    let onAccessibilityDecision: (SwipeAction) -> Void
    /// Runs the VoiceOver actions Previous photo and Next photo.
    var onAccessibilityStep: (PhotoStep) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let box = SortingLayout.photoBox(in: geometry.size)
            let cards = cards(in: box)
            let front = cards.first { $0.role == .front }
            ZStack {
                // Listed back to front, keyed by asset ID: when the current card leaves, the
                // card behind it is the same view moving up, not a new one.
                ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                    SwipeCard(card: card, deck: deck)
                        .zIndex(Double(index))
                        .transition(transition(for: card))
                }
            }
            .frame(width: front?.size.width ?? 0, height: front?.size.height ?? 0)
            // Accessibility frames the cards by everything they draw, clipped or not: the card
            // behind, the cards flying off and the overflow of aspect-filled images. A portrait
            // photo next made the stage taller than the screen, over Delete and Keep.
            .accessibilityHidden(true)
            .background { photoElement(isShown: front != nil) }
            .position(x: geometry.size.width / 2, y: SortingLayout.stageTopInset + box.height / 2)
            .onChange(of: geometry.size, initial: true) { _, size in
                deck.setStage(size, box: SortingLayout.photoBox(in: size))
            }
        }
        .coordinateSpace(.named(SwipeCard.coordinateSpace))
        // A photo back on Undo has its images from the loader again: the kept copy can go.
        .onChange(of: deck.hasReloadedLastDeparted) { _, isReloaded in
            if isReloaded {
                deck.releaseLastDeparted()
            }
        }
    }

    /// The current photo as VoiceOver, Full Keyboard Access and the keyboard know it: one element
    /// the size of the photo at rest (the stage's frame), which neither drags nor flights move.
    /// It has no content of its own, so it sits behind the cards and touches reach them.
    private func photoElement(isShown: Bool) -> some View {
        Color.clear
            .accessibilityElement()
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(accessibilityValue)
            .accessibilityAddTraits(.isImage)
            .accessibilityIdentifier(A11yID.Sorting.photo)
            .accessibilityActions {
                ForEach(PhotoAccessibilityAction.available(canGoBack: deck.canGoBack, canGoForward: deck.canGoForward), id: \.self) { action in
                    Button(action.name) { perform(action) }
                }
            }
            .accessibilityHidden(!isShown)
            .focusable()
            .focusEffectDisabled()
            .focused(keyFocus)
            .onKeyPress(keys: Self.actionKeys, phases: [.down, .repeat], action: onKeyPress)
    }

    /// Back to front: the next photo, the current one, then the cards flying off (the oldest on
    /// top, as it was before it left).
    private func cards(in box: CGSize) -> [StackCard] {
        let stack = deck.stack
        var cards: [StackCard] = []
        if let front = stack.front {
            let slot = deck.slot(for: front)
            let size = fittedSize(of: slot, in: box)
            if let behind = stack.behind {
                // The size of the photo in front, whatever the next photo's shape (it fills the
                // card), so the stack always shows as the same sliver under the current photo.
                // It takes its own shape as it moves to the front.
                cards.append(StackCard(id: behind, role: .behind, slot: deck.slot(for: behind), size: size))
            }
            cards.append(StackCard(id: front, role: .front, slot: slot, size: size, verdict: deck.session.state.verdict(for: front)))
        }
        for departure in deck.departures.reversed() where !cards.contains(where: { $0.id == departure.id }) {
            let size = fittedSize(of: departure.slot, in: box)
            let role = StackCard.Role.departing(offset: departure.offset, decides: departure.action != nil)
            cards.append(StackCard(id: departure.id, role: role, slot: departure.slot, size: size))
        }
        return cards
    }

    /// The photo, aspect-fit in `box`.
    private func fittedSize(of slot: PhotoSlot?, in box: CGSize) -> CGSize {
        Metrics.fit(aspectRatio: aspectRatio(of: slot), in: box)
    }

    /// From the metadata, else from whatever image has arrived, else 3:2.
    private func aspectRatio(of slot: PhotoSlot?) -> CGFloat {
        if let ratio = slot?.metadata?.aspectRatio {
            return ratio
        }
        if let image = slot?.displayImage, image.size.height > 0 {
            return image.size.width / image.size.height
        }
        return 3.0 / 2.0
    }

    /// A new card behind fades in; the photo coming back on Undo slides in from its side, and the
    /// one Previous brings back from the left, flat. Flying cards are removed off screen, so they
    /// just go.
    private func transition(for card: StackCard) -> AnyTransition {
        let removal: AnyTransition
        switch card.role {
        case .departing: removal = .identity
        case .behind, .front: removal = .opacity
        }
        if !reduceMotion, let returning = deck.returning, returning.id == card.id {
            return .asymmetric(insertion: .returning(from: returning.direction, distance: deck.flightDistance, tilts: returning.tilts), removal: removal)
        }
        return .asymmetric(insertion: .opacity, removal: removal)
    }

    /// What the card shows besides the photo: that it is zoomed in, the iCloud download, or that
    /// the sharp image couldn't be loaded.
    private var accessibilityValue: String {
        [deck.isCurrentPhotoZoomed ? "Zoomed in" : nil, loadingValue].compactMap { $0 }.joined(separator: ", ")
    }

    private var loadingValue: String? {
        guard let id = deck.session.state.currentAssetID, let slot = deck.slot(for: id), !slot.isSharp else { return nil }
        if slot.didFail {
            return "Couldn't load full resolution"
        }
        if let progress = slot.downloadProgress {
            return "Downloading from iCloud, \(progress.formatted(.percent.precision(.fractionLength(0))))"
        }
        return nil
    }

    /// Runs a VoiceOver action, then reads out the photo now on screen. The focus stays on the
    /// photo element, whose new label VoiceOver wouldn't read on its own; the announcement waits
    /// for any already under way ("Marked for deletion"), and for the photo's details when it
    /// has only just come into the window (see `currentPhotoLabel(in:)`).
    private func perform(_ action: PhotoAccessibilityAction) {
        switch action {
        case .decide(let action): onAccessibilityDecision(action)
        case .step(let step): onAccessibilityStep(step)
        }
        Task { [deck] in
            guard let label = await Self.currentPhotoLabel(in: deck) else { return }
            var announcement = AttributedString(label)
            announcement[AttributeScopes.AccessibilityAttributes.AnnouncementPriorityAttribute.self] = .low
            AccessibilityNotification.Announcement(announcement).post()
        }
    }

    /// The label of the photo on screen, filename and time included: Previous lands on a photo
    /// the loader had let go, whose details aren't in yet. Nil when no photo is on screen, or when
    /// another photo has come up meanwhile (its own action announces it).
    static func currentPhotoLabel(in deck: SwipeDeck) async -> String? {
        guard let id = deck.session.state.currentAssetID else { return nil }
        let metadata = await deck.metadata(for: id)
        let state = deck.session.state
        guard state.currentAssetID == id else { return nil }
        return photoLabel(position: state.position, total: state.total, metadata: metadata, verdict: state.verdict(for: id))
    }

    private var accessibilityLabel: String {
        let state = deck.session.state
        guard let id = state.currentAssetID else { return "" }
        return Self.photoLabel(position: state.position, total: state.total, metadata: deck.slot(for: id)?.metadata, verdict: state.verdict(for: id))
    }

    /// "Photo 38 of 400, IMG_4838.HEIC, 14:32", and for a photo already decided, its decision:
    /// "…, marked for deletion" or "…, kept".
    static func photoLabel(position: Int, total: Int, metadata: PhotoMetadata?, verdict: Verdict?) -> String {
        var parts = ["Photo \(position.formatted()) of \(total.formatted())"]
        if let metadata {
            parts.append(metadata.filename)
            if let date = metadata.creationDate {
                parts.append(date.formatted(date: .omitted, time: .shortened))
            }
        }
        if let verdict {
            parts.append(verdict.tagTitle.lowercased())
        }
        return parts.joined(separator: ", ")
    }
}

/// What VoiceOver can do with the photo: decide it, or move to the photo before or after it.
enum PhotoAccessibilityAction: Hashable {
    case decide(SwipeAction)
    case step(PhotoStep)

    var name: String {
        switch self {
        case .decide(let action): action.title
        case .step(let step): step.title
        }
    }

    /// Delete and Keep, then Previous photo and Next photo when there is a photo to go to.
    static func available(canGoBack: Bool, canGoForward: Bool) -> [PhotoAccessibilityAction] {
        SwipeAction.allCases.map(Self.decide)
            + (canGoBack ? [.step(.previous)] : [])
            + (canGoForward ? [.step(.next)] : [])
    }
}
