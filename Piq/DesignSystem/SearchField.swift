import SwiftUI

/// A search field: a raised capsule with a hairline, a magnifying glass, a muted prompt, and a
/// clear button while it holds text. At least 44pt tall; it grows with Dynamic Type. The owner
/// holds the focus, so keyboard shortcuts can move it in and out of the field.
///
/// It holds one line: Tab leaves the field instead of typing a tab (iPadOS moves the keyboard
/// into a text field with Tab, then types the next ones into it), and pasted line breaks become
/// spaces.
struct SearchField: View {
    let prompt: String
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    /// Return in the field.
    var onSubmit: () -> Void = {}
    /// Accessibility identifiers of the text field and of its clear button.
    var identifiers: (field: String, clear: String) = ("", "")

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.textMuted)
                .accessibilityHidden(true)
            TextField(prompt, text: singleLineText, prompt: Text(prompt).foregroundStyle(Palette.textMuted))
                .font(.text(16))
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused(isFocused)
                .onSubmit(onSubmit)
                .onKeyPress(.tab) {
                    isFocused.wrappedValue = false
                    return .handled
                }
                .accessibilityLabel(prompt)
                .accessibilityAddTraits(.isSearchField)
                .accessibilityIdentifier(identifiers.field)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Palette.textMuted)
                        .frame(width: Metrics.minTouch, height: Metrics.minTouch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier(identifiers.clear)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, text.isEmpty ? 14 : 0)
        .frame(minHeight: Metrics.minTouch)
        .background(Capsule().fill(Palette.raised))
        .overlay(
            Capsule().strokeBorder(isFocused.wrappedValue ? Palette.textMuted : Palette.hairlineStrong, lineWidth: 1)
                .animation(.easeOut(duration: 0.15), value: isFocused.wrappedValue)
        )
        .contentShape(Capsule())
        // The icon and the padding focus the field too, not just its text.
        .onTapGesture { isFocused.wrappedValue = true }
        .hoverEffect(.highlight)
    }

    private var singleLineText: Binding<String> {
        Binding {
            text
        } set: { newValue in
            text = Self.singleLine(newValue)
        }
    }

    /// `text` without tabs, and with its line breaks as spaces.
    static func singleLine(_ text: String) -> String {
        guard text.contains(where: { $0 == "\t" || $0.isNewline }) else { return text }
        return String(text.compactMap { character -> Character? in
            character == "\t" ? nil : character.isNewline ? " " : character
        })
    }
}
