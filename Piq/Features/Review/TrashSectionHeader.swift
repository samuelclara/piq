import SwiftUI

/// "Marked for deletion · tap to select" with Select all, Restore and Empty trash. The actions
/// sit on the right when there is room, move under the title in narrower windows, and take two
/// rows when even that is too tight. Each button keeps the width of its longest label, so the
/// layout depends on the window and the size of the trash, never on the selection: selecting a
/// photo can't push the grid down under the person's finger.
///
/// Keyboard: ⌘A selects everything, or deselects it once everything is selected.
struct TrashSectionHeader: View {
    let trashCount: Int
    let selectedCount: Int
    let isEverythingSelected: Bool
    let isEmptyingTrash: Bool
    /// Whether ⌘A is live: only while Review is on top with nothing over it.
    var acceptsShortcuts = false
    /// VoiceOver focus for Empty trash, which gets it back when the confirmation closes.
    var emptyTrashFocus: AccessibilityFocusState<Bool>.Binding?
    let toggleSelectAll: () -> Void
    let restore: () -> Void
    let emptyTrash: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                title
                    .fixedSize()
                Spacer(minLength: 24)
                actionRow
            }
            VStack(alignment: .leading, spacing: 14) {
                title
                actionRow
            }
            VStack(alignment: .leading, spacing: 14) {
                title
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        selectAllButton(fillsWidth: true)
                        restoreButton(fillsWidth: true)
                    }
                    emptyTrashButton(fillsWidth: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var title: some View {
        Text("\(Text(ReviewCopy.sectionTitle).foregroundStyle(Palette.text)) \(Text(ReviewCopy.sectionHint).font(.text(17)).foregroundStyle(Palette.textMuted))")
            .font(.text(17, .semibold))
            .accessibilityLabel("\(ReviewCopy.sectionTitle) \(ReviewCopy.sectionHint)".spoken)
            .accessibilityAddTraits(.isHeader)
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            selectAllButton()
            restoreButton()
            emptyTrashButton()
        }
    }

    private func selectAllButton(fillsWidth: Bool = false) -> some View {
        let label = isEverythingSelected ? "Deselect all" : "Select all"
        return Button(action: toggleSelectAll) {
            Text(label)
                .reservingWidth(of: "Deselect all")
                .frame(maxWidth: fillsWidth ? .infinity : nil)
        }
        .buttonStyle(.pill(.secondary))
        .disabled(isEmptyingTrash)
        .keyboardShortcut(acceptsShortcuts ? KeyboardShortcut("a", modifiers: .command) : nil)
        .accessibilityLabel(label)
        .accessibilityIdentifier(A11yID.Review.selectAll)
    }

    private func restoreButton(fillsWidth: Bool = false) -> some View {
        Button(action: restore) {
            Text(ReviewCopy.restoreButton(selectedCount))
                .contentTransition(.numericText(value: Double(selectedCount)))
                .reservingWidth(of: ReviewCopy.restoreButton(trashCount))
                .frame(maxWidth: fillsWidth ? .infinity : nil)
        }
        .buttonStyle(.pill(.secondary))
        .disabled(selectedCount == 0 || isEmptyingTrash)
        .accessibilityLabel(selectedCount > 0 ? "Restore \(Copy.photos(selectedCount))" : "Restore")
        .accessibilityHint("Takes the selected photos off the list")
        .accessibilityIdentifier(A11yID.Review.restore)
    }

    /// Keeps its coral fill while the trash empties and shows a spinner in place of the label.
    private func emptyTrashButton(fillsWidth: Bool = false) -> some View {
        Button(action: emptyTrash) {
            Text("Empty trash")
                .opacity(isEmptyingTrash ? 0 : 1)
                .overlay {
                    if isEmptyingTrash {
                        ProgressView()
                            .tint(Palette.ink)
                    }
                }
                .frame(maxWidth: fillsWidth ? .infinity : nil)
        }
        .buttonStyle(.pill(.destructive))
        .allowsHitTesting(!isEmptyingTrash)
        .accessibilityLabel(isEmptyingTrash ? "Emptying trash" : "Empty trash")
        .accessibilityHint(isEmptyingTrash ? "" : "Asks before moving \(Copy.photos(trashCount)) to Recently Deleted")
        .accessibilityIdentifier(A11yID.Review.emptyTrash)
        .accessibilityFocused(optional: emptyTrashFocus)
    }
}

private extension View {
    @ViewBuilder
    func accessibilityFocused(optional binding: AccessibilityFocusState<Bool>.Binding?) -> some View {
        if let binding {
            accessibilityFocused(binding)
        } else {
            self
        }
    }

    /// Lays the view out at least as wide as `text` would be (centered within that width), so a
    /// label that changes doesn't change the width of its button.
    func reservingWidth(of text: String) -> some View {
        ZStack {
            Text(text)
                .hidden()
                .accessibilityHidden(true)
            self
        }
    }
}
