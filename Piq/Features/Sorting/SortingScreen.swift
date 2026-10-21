import SwiftUI

/// Screen 2: the album's photos one at a time, as large as they fit. Swipe left to mark a photo
/// for deletion, right to keep it (or tap the pills, or press ← / →); Undo steps back. Previous
/// and Next (or ⌘[ / ⌘]) move through the photos without deciding.
struct SortingScreen: View {
    let session: SessionController

    @Environment(AppModel.self) private var app
    private var prepare: (SwipeDeck) -> Void = { _ in }

    init(session: SessionController) {
        self.session = session
    }

    var body: some View {
        SortingContent(session: session, app: app, prepare: prepare)
    }
}

/// The screen itself. It receives the app model so it can create its deck (and photo loader)
/// once, as state.
private struct SortingContent: View {
    let session: SessionController
    let app: AppModel

    @State private var deck: SwipeDeck
    /// Keyboard focus, held by the photo while sorting is on top (see `SortingStage`).
    @FocusState private var hasKeyFocus: Bool
    /// The window controls' width (iPadOS 26 windows), which narrows the top bar's center.
    @State private var windowControlsWidth: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(session: SessionController, app: AppModel, prepare: (SwipeDeck) -> Void) {
        self.session = session
        self.app = app
        let deck = SwipeDeck(session: session, app: app)
        prepare(deck)
        _deck = State(initialValue: deck)
    }

    /// Review is pushed on top of sorting and this view stays alive underneath, so keys and
    /// actions only work while sorting is the top screen.
    private var isTop: Bool {
        app.path.last == .sorting(albumID: session.albumID)
    }

    var body: some View {
        let state = session.state
        // Every photo decided, or past the last one (Review is on its way either way).
        let isDone = state.currentAssetID == nil && deck.departures.isEmpty
        GeometryReader { geometry in
            let width = geometry.size.width
            let stepsInTopBar = SortingBarFit.holdsStepButtons(
                width: width,
                textScale: SortingBarFit.textScale(at: dynamicTypeSize),
                leadingInset: Metrics.topBarLeadingInset(clearing: windowControlsWidth)
            )
            VStack(spacing: 0) {
                SortingTopBar(
                    width: width,
                    title: session.albumTitle,
                    state: state,
                    canUndo: deck.canUndo,
                    showsStepButtons: stepsInTopBar,
                    canGoBack: deck.canGoBack,
                    canGoForward: deck.canGoForward,
                    acceptsShortcuts: isTop,
                    onBack: returnToAlbums,
                    onUndo: undo,
                    onReview: showReview,
                    onStep: step
                )
                .zIndex(2)
                if isDone {
                    SortingCompleteView(
                        total: state.total,
                        sortedCount: state.sortedCount,
                        markedCount: state.markedCount,
                        onReview: showReview,
                        onAlbums: returnToAlbums,
                        onContinue: continueSorting
                    )
                    if !stepsInTopBar {
                        stepRow(width: width)
                            .padding(.bottom, 18)
                    }
                } else {
                    // Above the controls, so a dragged photo passes over them.
                    SortingStage(deck: deck, keyFocus: $hasKeyFocus, onKeyPress: handleKey, onAccessibilityDecision: decideNow, onAccessibilityStep: step)
                        .zIndex(1)
                    if !stepsInTopBar {
                        stepRow(width: width)
                            .padding(.bottom, SortingLayout.stepRowSpacing)
                    }
                    SortingControls(buttonWidth: SortingLayout.actionButtonWidth(forWidth: width), acceptsShortcuts: isTop, onDecide: decide)
                        .padding(.bottom, 18)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: isDone)
        }
        .onWindowControlsWidthChange { windowControlsWidth = $0 }
        .background(Palette.ground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden()
        .onAppear(perform: appear)
        .onDisappear(perform: disappear)
        .onChange(of: state.window(lookahead: PhotoWindowLoader.lookahead)) { _, window in
            deck.show(window)
        }
        .onChange(of: state.currentAssetID) { _, id in
            deck.currentPhotoChanged(to: id)
        }
        .onChange(of: isTop) { _, isTop in
            // Back from Review, which took the focus.
            if isTop {
                hasKeyFocus = true
            }
        }
        .onChange(of: reduceMotion, initial: true) { _, reduceMotion in
            deck.reduceMotion = reduceMotion
        }
    }

    /// Previous and Next in a narrow window: a row under the photo, over Delete and Keep, clear
    /// of the toasts that come down under the top bar.
    private func stepRow(width: CGFloat) -> some View {
        PhotoStepRow(canGoBack: deck.canGoBack, canGoForward: deck.canGoForward, acceptsShortcuts: isTop, onStep: step)
            .padding(.horizontal, Metrics.pageMargin(forWidth: width))
    }

    // MARK: Actions

    /// ← deletes and → keeps while sorting is on top, once per press (see `SortingKeyResponse`).
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard isTop else { return .ignored }
        switch SortingKeyResponse(key: press.key, modifiers: press.modifiers, phase: press.phase) {
        case .decide(let action):
            decide(action)
            return .handled
        case .swallow:
            return .handled
        case .ignore:
            return .ignored
        }
    }

    private func decide(_ action: SwipeAction) {
        guard isTop else { return }
        deck.decide(action)
    }

    private func decideNow(_ action: SwipeAction) {
        guard isTop else { return }
        deck.decideNow(action)
    }

    private func undo() {
        guard isTop else { return }
        deck.undo()
    }

    private func step(_ step: PhotoStep) {
        guard isTop else { return }
        deck.step(step)
    }

    /// From the end of the album with photos skipped: back to the first of them.
    private func continueSorting() {
        guard isTop else { return }
        session.goToFirstUnsorted()
    }

    private func showReview() {
        deck.finish()
        app.showReview()
    }

    private func returnToAlbums() {
        deck.finish()
        app.returnToAlbums()
    }

    private func appear() {
        hasKeyFocus = true
        deck.appear()
    }

    private func disappear() {
        deck.disappear()
    }
}

/// What a key press does on the sorting screen: ← deletes and → keeps
/// (`SwipeAction.keyEquivalent`), without modifiers, and only when the key goes down. Holding a
/// key decides one photo, not one per repeat: a held ← would otherwise mark photo after photo for
/// deletion before anyone saw them.
enum SortingKeyResponse: Equatable {
    /// Decide the current photo.
    case decide(SwipeAction)
    /// Take the key and do nothing: a held arrow key repeating. Taking it keeps the repeat from
    /// moving the keyboard focus or reaching the pills' shortcuts.
    case swallow
    /// Not a sorting key (or with modifiers, such as ⌘Z's): for the rest of the app.
    case ignore

    init(key: KeyEquivalent, modifiers: EventModifiers, phase: KeyPress.Phases) {
        guard modifiers.isDisjoint(with: [.command, .option, .control, .shift]),
              let action = SwipeAction.allCases.first(where: { $0.keyEquivalent == key }) else {
            self = .ignore
            return
        }
        self = phase == .down ? .decide(action) : .swallow
    }
}

#if DEBUG
extension SortingScreen {
    /// Holds the current photo mid-swipe, `translation` away from its resting place, so a
    /// preview can show the swipe overlay.
    init(session: SessionController, previewDrag translation: CGSize) {
        self.init(session: session)
        prepare = { $0.holdDrag(translation) }
    }
}

#Preview("Sorting", traits: .landscapeLeft) {
    let (app, session) = PreviewSupport.session(.sorting)
    SortingScreen(session: session).environment(app)
}

#Preview("Sorting · portrait", traits: .portrait) {
    let (app, session) = PreviewSupport.session(.sorting)
    SortingScreen(session: session).environment(app)
}

#Preview("Sorting · narrow", traits: .fixedLayout(width: 600, height: 834)) {
    let (app, session) = PreviewSupport.session(.sorting)
    SortingScreen(session: session).environment(app)
}

#Preview("Sorting · loading", traits: .landscapeLeft) {
    let app = PreviewSupport.appModel(.sorting, fullImageLatency: .seconds(60))
    if let session = app.activeSession {
        SortingScreen(session: session).environment(app)
    }
}

#Preview("Sorting · swiping left", traits: .landscapeLeft) {
    let (app, session) = PreviewSupport.session(.sorting)
    SortingScreen(session: session, previewDrag: CGSize(width: -150, height: 12)).environment(app)
}

#Preview("Sorting · swiping right", traits: .portrait) {
    let (app, session) = PreviewSupport.session(.sorting)
    SortingScreen(session: session, previewDrag: CGSize(width: 90, height: -8)).environment(app)
}

#Preview("Sorting · first photo", traits: .landscapeLeft) {
    let (app, session) = PreviewSupport.session(.sortingStart)
    SortingScreen(session: session).environment(app)
}

#Preview("Sorting · back on a photo marked for deletion", traits: .landscapeLeft) {
    let (app, session) = PreviewSupport.session(.sorting)
    PreviewSupport.stepBack(session, toPhotoDecided: .delete)
    return SortingScreen(session: session).environment(app)
}

#Preview("Sorting · back on a kept photo", traits: .portrait) {
    let (app, session) = PreviewSupport.session(.sorting)
    PreviewSupport.stepBack(session, toPhotoDecided: .keep)
    return SortingScreen(session: session).environment(app)
}

#Preview("Sorting · past the last photo, some skipped", traits: .landscapeLeft) {
    let (app, session) = PreviewSupport.session(.sorting)
    while session.step(.next) {}
    return SortingScreen(session: session).environment(app)
}

#Preview("Sorting · all sorted", traits: .landscapeLeft) {
    let (app, session) = PreviewSupport.session(.review)
    SortingScreen(session: session).environment(app)
}

#Preview("Sorting · largest text", traits: .fixedLayout(width: 600, height: 834)) {
    let (app, session) = PreviewSupport.session(.sorting)
    SortingScreen(session: session).environment(app)
        .dynamicTypeSize(.xxLarge)
}
#endif
