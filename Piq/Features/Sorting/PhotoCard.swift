import SwiftUI

/// What a card shows: a blurred preview until the sharp image arrives, then a crossfade to it.
/// The card in front also shows the filename chip, the photo's decision when it has one (the
/// person came back to it), and a spinner (with iCloud progress) when the sharp image is slow to
/// come.
struct PhotoCard: View {
    let assetID: String
    let slot: PhotoSlot?
    let size: CGSize
    /// The chip and the loading state; the card behind the current one shows the photo alone.
    let showsDetails: Bool
    /// The photo's decision, shown as a tag next to the chip; nil while it is unsorted.
    var verdict: Verdict?

    /// Set once the card has been up a moment without its sharp image: the sharp image then fades
    /// in over what was seen (the preview or the placeholder). One that comes sooner (from the
    /// cache, while photos are skipped quickly) replaces it at once, so fast sorting never shows a
    /// stream of crossfades.
    @State private var hasWaited = false
    /// Set once the sharp image has kept us waiting a while, so fast loads never flash a spinner.
    @State private var isSlow = false

    var body: some View {
        let isSharp = slot?.isSharp == true
        ZStack {
            if !isSharp {
                if let preview = slot?.preview {
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 20, opaque: true)
                        // Stays put under the sharp image while it fades in, then goes.
                        .transition(.asymmetric(insertion: .opacity, removal: .opacity.animation(.linear(duration: 0.01).delay(0.2))))
                } else {
                    PhotoPlaceholder()
                }
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
        .animation(hasWaited ? .easeOut(duration: 0.2) : nil, value: isSharp)
        .animation(.easeOut(duration: 0.15), value: slot?.preview != nil)
        .overlay(alignment: .top) { topRow }
        .overlay(alignment: .bottomLeading) { failureChip }
        .overlay { loadingIndicator }
        .task(id: assetID) {
            hasWaited = false
            isSlow = false
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            hasWaited = true
            try? await Task.sleep(for: .milliseconds(130))
            if !Task.isCancelled {
                isSlow = true
            }
        }
        .onChange(of: frontState, initial: true) { _, state in
            guard let state else { return }
            ImageSignposts.signposter.emitEvent("Card", "\(assetID, privacy: .public) \(state.rawValue, privacy: .public)")
        }
    }

    /// What the card shows while it's in front (nil behind), for the "Card" signpost.
    private var frontState: FrontState? {
        guard showsDetails else { return nil }
        if slot?.isSharp == true { return .sharp }
        if isSlow, slot?.didFail != true { return .spinner }
        return slot?.preview == nil ? .placeholder : .blurred
    }

    private enum FrontState: String {
        case placeholder, blurred, spinner, sharp
    }

    private var chipInset: CGFloat { 14 }

    /// The filename chip on the left and the decision tag on the right. On the card in front
    /// only, so the card behind holds no hidden text; they fade in as the card moves up. When the
    /// photo is too narrow for both whole (a third-width window, larger text), the tag drops its
    /// words for its icon, so the filename keeps its content; the photo's VoiceOver label says
    /// the decision either way.
    @ViewBuilder
    private var topRow: some View {
        if showsDetails {
            ViewThatFits(in: .horizontal) {
                topRowContent(isCompact: false)
                topRowContent(isCompact: true)
            }
            .frame(width: max(size.width - 2 * chipInset, 0), alignment: .leading)
            .padding(chipInset)
            .animation(.easeOut(duration: 0.15), value: verdict)
        }
    }

    /// The chip and the tag side by side: both whole (`ViewThatFits` takes it only if it fits),
    /// or the tag as an icon and the chip shortened if even that is too wide.
    private func topRowContent(isCompact: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if let text = slot?.metadata?.chipText {
                PhotoChip(text: text)
                    .fixedSize(horizontal: !isCompact, vertical: false)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
            if let verdict {
                DecisionTag(verdict: verdict, isCompact: isCompact)
                    .layoutPriority(1)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var failureChip: some View {
        if showsDetails, slot?.didFail == true {
            PhotoChip(text: "Couldn't load full resolution")
                .padding(chipInset)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var loadingIndicator: some View {
        if showsDetails, isSlow, slot?.isSharp != true, slot?.didFail != true {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Palette.text)
                if let progress = slot?.downloadProgress {
                    Text("Downloading from iCloud")
                        .font(.hint)
                        .foregroundStyle(Palette.text)
                    ThinProgressBar(progress: progress, width: 140)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.42)))
            .transition(.opacity)
        }
    }
}
