import SwiftUI

/// The bar pinned under the album grid: the selected album on the left and the large
/// "Start sorting · 400 photos" / "Resume · 38 of 400" button on the right (see `startTitle`).
/// An album with a session also offers "Cancel session", which asks first, then forgets it.
struct PickerBottomBar: View {
    let layout: PickerLayout
    /// Whether Return presses the start button: not while the search field has the keyboard,
    /// where Return ends the search.
    var acceptsReturn = true

    @Environment(AppModel.self) private var app
    @State private var isConfirmingCancel = false

    var body: some View {
        let album = app.selectedAlbum
        let resume = album.flatMap { app.resumePoint(for: $0.id) }
        Group {
            if layout.isNarrow {
                stacked(album, resume)
            } else if resume != nil {
                // Cancel session takes room from the album's name: stacked rather than cut short.
                ViewThatFits(in: .horizontal) {
                    row(album, resume)
                    stacked(album, resume)
                }
            } else {
                row(album, resume)
            }
        }
        .padding(.horizontal, layout.margin)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Hairline() }
    }

    /// The selected album above full-width buttons: "Resume", then "Cancel session".
    private func stacked(_ album: AlbumSummary?, _ resume: ResumePoint?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SelectionSummary(album: album)
            startButton(for: album, resume: resume, fillsWidth: true)
            if let album, let resume {
                cancelButton(for: album, resume: resume, fillsWidth: true)
            }
        }
    }

    /// The selected album on the left, "Cancel session" and the start button on the right.
    private func row(_ album: AlbumSummary?, _ resume: ResumePoint?) -> some View {
        HStack(spacing: 20) {
            SelectionSummary(album: album)
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                if let album, let resume {
                    cancelButton(for: album, resume: resume, fillsWidth: false)
                }
                startButton(for: album, resume: resume, fillsWidth: false)
            }
            .layoutPriority(1)
        }
    }

    private func startButton(for album: AlbumSummary?, resume: ResumePoint?, fillsWidth: Bool) -> some View {
        let isOpening = app.isOpeningAlbum
        let title = Self.startTitle(for: album, resume: resume)
        return Button {
            guard let album, !app.isOpeningAlbum else { return }
            Task { await app.openAlbum(album) }
        } label: {
            HStack(spacing: 10) {
                if isOpening {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Palette.ink)
                }
                Text(title)
            }
            .frame(maxWidth: fillsWidth ? .infinity : nil)
        }
        .buttonStyle(.pill(.primary, height: Metrics.largeButtonHeight, font: .largeButtonLabel))
        .disabled(album == nil || album?.photoCount == 0)
        // Busy, not disabled, while the album opens: the pill keeps its full strength so the
        // spinner reads as "working", and further taps (and Return) are ignored.
        .allowsHitTesting(!isOpening)
        .accessibilityLabel(title.spoken)
        .accessibilityValue(isOpening ? "Opening" : "")
        // Only while the picker is on screen, so Return can't reopen an album from a pushed screen.
        .keyboardShortcut(app.path.isEmpty && acceptsReturn ? .defaultAction : nil)
        .accessibilityIdentifier(A11yID.Picker.startButton)
    }

    /// "Cancel session": asks first (a popover on the button), then forgets the album's session.
    private func cancelButton(for album: AlbumSummary, resume: ResumePoint, fillsWidth: Bool) -> some View {
        Button {
            isConfirmingCancel = true
        } label: {
            Text("Cancel session")
                .frame(maxWidth: fillsWidth ? .infinity : nil)
        }
        .buttonStyle(.pill(.secondary, height: Metrics.largeButtonHeight, font: .largeButtonLabel))
        .disabled(app.isOpeningAlbum)
        .accessibilityIdentifier(A11yID.Picker.cancelSession)
        .confirmationDialog("Cancel the session for \(album.title)?", isPresented: $isConfirmingCancel, titleVisibility: .visible) {
            Button("Cancel Session", role: .destructive) {
                app.cancelSession(albumID: album.id)
            }
            Button("Keep Session", role: .cancel) {}
        } message: {
            Text(Self.cancelMessage(for: resume))
        }
    }

    /// What cancelling forgets. Marked photos are only on Piq's list, so Photos keeps them.
    static func cancelMessage(for resume: ResumePoint) -> String {
        let marked = resume.markedCount > 0 ? ", including the \(Copy.photos(resume.markedCount)) marked for deletion" : ""
        return "Piq forgets every decision you made in this album\(marked), and it starts over. Nothing changes in Photos."
    }

    /// "Start sorting · 400 photos"; "Resume · 38 of 400" when the album has an unfinished session;
    /// "Review · 50 photos marked" when every photo is sorted but Piq's trash still holds some
    /// (the button then opens the review screen).
    static func startTitle(for album: AlbumSummary?, resume: ResumePoint?) -> String {
        guard let album else { return "Start sorting" }
        guard let resume else { return "Start sorting · \(Copy.photos(album.photoCount))" }
        if resume.isComplete {
            return "Review · \(Copy.photos(resume.markedCount)) marked"
        }
        return "Resume · \(resume.position.formatted()) of \(resume.total.formatted())"
    }
}

/// "Selected: Iceland 2026", or a prompt when nothing is selected yet.
private struct SelectionSummary: View {
    let album: AlbumSummary?

    var body: some View {
        HStack(spacing: 6) {
            if let album {
                Text("Selected:")
                    .foregroundStyle(Palette.textMuted)
                    .fixedSize()
                Text(album.title)
                    .font(.text(17, .semibold))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
            } else {
                Text("Select an album")
                    .foregroundStyle(Palette.textMuted)
                    .lineLimit(1)
            }
        }
        .font(.lead)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(album.map { "Selected: \($0.title)" } ?? "Select an album")
    }
}
