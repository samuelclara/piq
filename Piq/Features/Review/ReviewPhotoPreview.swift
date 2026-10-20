import SwiftUI

/// A full-screen look at one photo in the trash, opened by long-pressing its tile. The quick
/// preview shows right away and the sharp image replaces it when it arrives. If the sharp image
/// can't be loaded, a notice says so and offers to try again. Close it with the button, Escape,
/// or by dragging the photo down (the system's zoom transition handles the drag on iOS 18 and
/// later; see `ReviewPreviewZoom`).
struct ReviewPhotoPreview: View {
    let assetID: String
    /// Details loaded by the review screen; the loader fetches them when they're missing.
    let metadata: PhotoMetadata?

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var loader: ReviewPreviewLoader?
    /// How far the photo has been dragged down.
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        let slot = loader?.slot
        let details = metadata ?? slot?.metadata
        let didFail = loader?.didFail == true
        let failureMessage = loader?.quickPreview == nil ? ReviewCopy.photoFailed : ReviewCopy.previewFailed
        ZStack {
            Palette.ground
                .ignoresSafeArea()
            GeometryReader { proxy in
                PreviewPhoto(
                    slot: slot,
                    quickPreview: loader?.quickPreview,
                    aspectRatio: details?.aspectRatio,
                    label: ReviewCopy.photoLabel(details),
                    container: proxy.size
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .ignoresSafeArea()
            .offset(y: dragOffset)
            .scaleEffect(1 - min(dragOffset / 2400, 0.12))
            controls(chipText: details?.chipText, failureMessage: didFail ? failureMessage : nil)
                .opacity(1 - min(dragOffset / 160, 1))
        }
        .contentShape(Rectangle())
        .gesture(dragToDismiss, including: ReviewPreviewZoom.isAvailable ? .subviews : .all)
        .statusBarHidden()
        .accessibilityAction(.escape) { dismiss() }
        .onAppear(perform: startLoading)
        .onDisappear { loader?.release() }
        .onChange(of: didFail) { _, didFail in
            if didFail {
                AccessibilityNotification.Announcement(failureMessage).post()
            }
        }
    }

    /// The chip and the close button; and, when the sharp image failed, `failureMessage` with a
    /// way to try again.
    private func controls(chipText: String?, failureMessage: String?) -> some View {
        VStack(spacing: 0) {
            HStack {
                if let chipText {
                    PhotoChip(text: chipText)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 16)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Palette.text)
                        .frame(width: Metrics.minTouch, height: Metrics.minTouch)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                        .contentShape(Circle())
                        .contentShape(.hoverEffect, Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
                .accessibilityIdentifier(A11yID.Review.closePreview)
            }
            .leadingPaddingClearingWindowControls(0)
            Spacer(minLength: 20)
            if let failureMessage {
                LoadFailedNotice(message: failureMessage) {
                    loader?.retry()
                }
                .transition(.opacity)
            }
        }
        .padding(20)
        .animation(.easeOut(duration: 0.25), value: failureMessage)
    }

    private var dragToDismiss: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                let distance = value.translation.height
                dragOffset = distance > 0 ? distance : distance / 6
            }
            .onEnded { value in
                if value.translation.height > 120 || value.predictedEndTranslation.height > 360 {
                    dismiss()
                } else {
                    withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.32, dampingFraction: 0.86)) {
                        dragOffset = 0
                    }
                }
            }
    }

    private func startLoading() {
        if loader == nil {
            loader = ReviewPreviewLoader(assetID: assetID, images: app.images, library: app.library)
        }
        loader?.start()
    }
}

/// The photo, aspect-fit and as large as the screen allows: the blurred quick preview first,
/// then the sharp image, with a spinner while it loads. If the sharp image fails, the quick
/// preview is all there is, so it shows unblurred (the notice says it isn't the full photo).
private struct PreviewPhoto: View {
    let slot: PhotoSlot?
    /// The slot's quick preview, or a failed attempt's while a retry loads.
    let quickPreview: UIImage?
    let aspectRatio: CGFloat?
    /// VoiceOver label: "Photo, IMG_4838.HEIC, 14:32".
    let label: String
    let container: CGSize

    var body: some View {
        let size = Metrics.fit(aspectRatio: ratio, in: container)
        let didFail = slot?.didFail == true
        ZStack {
            if let preview = quickPreview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: didFail ? 0 : 18, opaque: true)
            } else {
                PhotoPlaceholder(showsIcon: didFail)
            }
            if let image = slot?.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .overlay {
            if isLoading {
                ProgressView()
                    .controlSize(.large)
                    .tint(Palette.text)
                    .padding(14)
                    .background(Circle().fill(Color.black.opacity(0.45)))
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: slot?.isSharp)
        .animation(.easeOut(duration: 0.25), value: didFail)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isImage)
    }

    /// Width / height: from the photo's details, else the image that has loaded, else 3:2.
    private var ratio: CGFloat {
        if let aspectRatio { return aspectRatio }
        if let image = slot?.image ?? quickPreview, image.size.height > 0 { return image.size.width / image.size.height }
        return 3.0 / 2.0
    }

    private var isLoading: Bool {
        guard let slot else { return true }
        return !slot.isSharp && !slot.didFail
    }
}

/// "Couldn't load the full-resolution photo" ("Couldn't load this photo" when there is no quick
/// preview either), with a button to try again. Shown over the bottom of the preview when the
/// sharp image fails: an iCloud photo while offline, or a photo that is gone from the library.
private struct LoadFailedNotice: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        // A 56pt-tall capsule on one line; a rounded card if the message wraps.
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        HStack(spacing: 14) {
            Label(message, systemImage: ReviewCopy.problemSymbol)
                .font(.toast)
                .foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
            Button(ReviewCopy.tryAgain, action: retry)
                .buttonStyle(.pill(.secondary))
                .fixedSize()
        }
        .padding(.leading, 20)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(shape.fill(Color.black.opacity(0.6)))
        .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }
}
