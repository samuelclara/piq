import SwiftUI

/// Screen 3: the photos marked for deletion. Take some off the list, then empty the trash, which
/// moves the rest to Recently Deleted in Photos after the system's own confirmation.
struct ReviewScreen: View {
    let session: SessionController

    @Environment(AppModel.self) private var app
    @State private var model = ReviewModel()
    @Namespace private var previewZoom
    /// VoiceOver focus on Empty trash, given back to it when the confirmation closes.
    @AccessibilityFocusState private var isEmptyTrashFocused: Bool

    init(session: SessionController) {
        self.session = session
    }

    #if DEBUG
    /// For previews: opens with `selection` selected, and with the delete confirmation showing.
    init(session: SessionController, selection: Set<String>, confirmingDelete: Bool = false) {
        self.session = session
        _model = State(initialValue: ReviewModel(selection: selection, isConfirmingDelete: confirmingDelete))
    }
    #endif

    var body: some View {
        let state = session.state
        let trash = state.markedInOrder
        GeometryReader { proxy in
            let margin = Metrics.pageMargin(forWidth: proxy.size.width)
            VStack(spacing: 0) {
                ReviewTopBar(albumTitle: session.albumTitle, backTitle: state.isComplete ? "Albums" : "Continue sorting") {
                    app.continueSorting()
                }
                ReviewHeader(state: state)
                    .padding(.horizontal, margin)
                    .padding(.top, 32)
                if trash.isEmpty {
                    ReviewEmptyState(buttonTitle: state.isComplete ? "Back to albums" : "Continue sorting") {
                        app.continueSorting()
                    }
                    .transition(.opacity)
                } else {
                    TrashSection(
                        trash: trash,
                        containerWidth: proxy.size.width,
                        margin: margin,
                        session: session,
                        model: model,
                        previewZoom: previewZoom,
                        acceptsShortcuts: acceptsShortcuts,
                        emptyTrashFocus: $isEmptyTrashFocused
                    ) {
                        model.isConfirmingDelete = true
                    }
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(.easeInOut(duration: 0.3), value: trash.isEmpty)
        }
        .background(Palette.ground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden()
        .modalCard(isPresented: $model.isConfirmingDelete) {
            DeleteConfirmationCard(count: state.markedCount) {
                model.isConfirmingDelete = false
            } confirm: {
                emptyTrash()
            }
        }
        .fullScreenCover(item: $model.preview) { target in
            ReviewPhotoPreview(assetID: target.id, metadata: model.metadata[target.id])
                .reviewZoomTransition(from: target.id, in: previewZoom)
                .environment(app)
        }
        .task(id: state.markedIDs) {
            await model.loadMetadata(for: trash, from: app.library)
        }
        .onChange(of: state.markedIDs) { _, trash in
            model.trashChanged(to: trash)
        }
        .onChange(of: model.isConfirmingDelete) { _, isConfirming in
            if !isConfirming, !session.state.markedIDs.isEmpty {
                isEmptyTrashFocused = true
            }
        }
    }

    /// Review's shortcuts work only while it is the top screen with nothing presented over it.
    private var acceptsShortcuts: Bool {
        app.path.last == .review(albumID: session.albumID) && model.preview == nil && !model.isConfirmingDelete
    }

    /// Closes the card, then asks Photos to delete the whole trash. A second tap while the card
    /// animates away does nothing.
    private func emptyTrash() {
        guard model.isConfirmingDelete else { return }
        model.isConfirmingDelete = false
        Task {
            await model.emptyTrash(in: session, toasts: app.toasts)
        }
    }
}

/// The section header and the grid under it. Owns the hairline that appears once the grid
/// scrolls, so scrolling doesn't re-render the rest of the screen.
private struct TrashSection: View {
    let trash: [String]
    let containerWidth: CGFloat
    let margin: CGFloat
    let session: SessionController
    let model: ReviewModel
    let previewZoom: Namespace.ID
    let acceptsShortcuts: Bool
    let emptyTrashFocus: AccessibilityFocusState<Bool>.Binding
    let confirmEmptyTrash: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isScrolled = false

    var body: some View {
        let marked = session.state.markedIDs
        VStack(spacing: 0) {
            TrashSectionHeader(
                trashCount: marked.count,
                selectedCount: model.selection.count,
                isEverythingSelected: model.isEverythingSelected(in: marked),
                isEmptyingTrash: session.isEmptyingTrash,
                acceptsShortcuts: acceptsShortcuts,
                emptyTrashFocus: emptyTrashFocus,
                toggleSelectAll: {
                    withAnimation(.easeOut(duration: 0.16)) {
                        model.toggleSelectAll(in: marked)
                    }
                },
                restore: {
                    // The grid closes the gaps by sliding tiles across rows: not with Reduce Motion.
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.32)) {
                        model.restoreSelection(in: session, toasts: app.toasts)
                    }
                },
                emptyTrash: {
                    guard !session.isEmptyingTrash else { return }
                    confirmEmptyTrash()
                }
            )
            .padding(.horizontal, margin)
            .padding(.top, 32)
            .padding(.bottom, 16)
            .overlay(alignment: .bottom) {
                Hairline()
                    .opacity(isScrolled ? 1 : 0)
            }
            .zIndex(1)
            // A group of its own: otherwise VoiceOver lands on the hairline, hidden as it is, as
            // an empty element between Empty trash and the first photo.
            .accessibilityElement(children: .contain)

            TrashGrid(trash: trash, containerWidth: containerWidth, margin: margin, model: model, previewZoom: previewZoom) { scrolled in
                withAnimation(.easeOut(duration: 0.2)) {
                    isScrolled = scrolled
                }
            }
        }
    }
}

#if DEBUG
#Preview("All sorted", traits: .landscapeLeft) {
    let (app, session) = PreviewSupport.session(.review)
    ReviewScreen(session: session)
        .environment(app)
}

#Preview("Partly sorted", traits: .landscapeLeft) {
    let (app, session) = PreviewSupport.session(.reviewPartial)
    ReviewScreen(session: session)
        .environment(app)
}

#Preview("Selection", traits: .landscapeLeft) {
    let (app, session) = PreviewSupport.session(.review)
    ReviewScreen(session: session, selection: Set(session.state.markedInOrder.prefix(3)))
        .environment(app)
}

#Preview("Empty trash", traits: .landscapeLeft) {
    let (app, session) = PreviewSupport.session(.emptyTrash)
    ReviewScreen(session: session)
        .environment(app)
}

#Preview("Confirm delete", traits: .landscapeLeft) {
    let (app, session) = PreviewSupport.session(.review)
    ReviewScreen(session: session, selection: [], confirmingDelete: true)
        .environment(app)
}

#Preview("Portrait", traits: .portrait) {
    let (app, session) = PreviewSupport.session(.reviewPartial)
    ReviewScreen(session: session)
        .environment(app)
}

#Preview("Narrow", traits: .fixedLayout(width: 600, height: 834)) {
    let (app, session) = PreviewSupport.session(.review)
    ReviewScreen(session: session)
        .environment(app)
}

#Preview("Largest text", traits: .fixedLayout(width: 600, height: 834)) {
    let (app, session) = PreviewSupport.session(.review)
    ReviewScreen(session: session, selection: Set(session.state.markedInOrder.prefix(2)))
        .environment(app)
        .dynamicTypeSize(.xxLarge)
}
#endif
