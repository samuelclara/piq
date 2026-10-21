import SwiftUI

extension A11yID.Picker {
    static let search = "picker.search"
    static let clearSearch = "picker.search.clear"
    static let sort = "picker.sort"
    static let noMatches = "picker.noMatches"
    static let noMatchesClear = "picker.noMatches.clear"
    static let openPhotos = "picker.openPhotos"
}

/// The search field and the sort menu, side by side. The field takes the room it's given up to
/// a comfortable width; the menu keeps its size. The menu is left out when there is nothing for
/// it to order (see `AlbumBrowsing.offersSort`).
struct AlbumTools: View {
    /// The field's width when nothing constrains it, and the most it grows to.
    static let searchWidth: (ideal: CGFloat, max: CGFloat) = (280, 360)

    @Binding var searchText: String
    @Binding var sortOrder: AlbumSortOrder
    var isSearchFocused: FocusState<Bool>.Binding
    let showsSort: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Return leaves the field and keeps the filter: it's the end of a search, never a
            // request to start sorting (the selected album may not even be on screen).
            SearchField(
                prompt: "Search albums",
                text: $searchText,
                isFocused: isSearchFocused,
                onSubmit: { isSearchFocused.wrappedValue = false },
                identifiers: (A11yID.Picker.search, A11yID.Picker.clearSearch)
            )
            .frame(minWidth: 0, idealWidth: Self.searchWidth.ideal, maxWidth: Self.searchWidth.max)
            if showsSort {
                AlbumSortMenu(order: $sortOrder)
                    .fixedSize()
            }
        }
    }
}

/// "Sort" with a menu of the two orders; the current one has a check mark.
struct AlbumSortMenu: View {
    @Binding var order: AlbumSortOrder

    var body: some View {
        Menu {
            Picker("Sort albums by", selection: $order) {
                ForEach(AlbumSortOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 14, weight: .medium))
                Text("Sort")
            }
        }
        .menuStyle(.button)
        .buttonStyle(.pill(.secondary))
        .accessibilityLabel("Sort albums")
        .accessibilityValue(order.title)
        .accessibilityIdentifier(A11yID.Picker.sort)
    }
}

/// The picker's title and subtitle, and on the album page the search and sort tools. The tools
/// sit on the title's line, right-aligned, when the width has room for both (the landscape
/// design, where the page then keeps its height); otherwise they get a row of their own under
/// the subtitle, still right-aligned. One layout for both arrangements keeps the search field,
/// and its focus, when the window changes size or the text size changes.
struct PickerIntroLayout: Layout {
    static let subtitleSpacing: CGFloat = 10
    /// Least space between the title and the tools on one line.
    static let inlineSpacing: CGFloat = 24
    /// Space above the tools' own row.
    static let rowSpacing: CGFloat = 20

    /// Where the parts go for a width.
    private struct Arrangement {
        var title: CGRect
        var subtitle: CGRect
        var tools: CGRect?
        var height: CGFloat
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        return CGSize(width: width, height: arrangement(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let parts = arrangement(width: bounds.width, subviews: subviews)
        let frames = [parts.title, parts.subtitle] + (parts.tools.map { [$0] } ?? [])
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    /// Whether the tools fit on the title's line at `width`.
    static func toolsFitBesideTitle(width: CGFloat, titleWidth: CGFloat, toolsWidth: CGFloat) -> Bool {
        titleWidth + inlineSpacing + toolsWidth <= width
    }

    private func arrangement(width: CGFloat, subviews: Subviews) -> Arrangement {
        guard subviews.count >= 2 else { return Arrangement(title: .zero, subtitle: .zero, tools: nil, height: 0) }
        let title = subviews[0]
        let subtitle = subviews[1]
        let tools = subviews.count > 2 ? subviews[2] : nil
        let full = ProposedViewSize(width: width, height: nil)
        let subtitleHeight = subtitle.sizeThatFits(full).height

        if let tools {
            let toolsIdeal = tools.sizeThatFits(.unspecified)
            let titleIdeal = title.sizeThatFits(.unspecified)
            if Self.toolsFitBesideTitle(width: width, titleWidth: titleIdeal.width, toolsWidth: toolsIdeal.width) {
                let line = max(titleIdeal.height, toolsIdeal.height)
                let titleFrame = CGRect(x: 0, y: ((line - titleIdeal.height) / 2).rounded(), width: width - toolsIdeal.width - Self.inlineSpacing, height: titleIdeal.height)
                let toolsFrame = CGRect(x: width - toolsIdeal.width, y: ((line - toolsIdeal.height) / 2).rounded(), width: toolsIdeal.width, height: toolsIdeal.height)
                let subtitleY = line + Self.subtitleSpacing
                return Arrangement(
                    title: titleFrame,
                    subtitle: CGRect(x: 0, y: subtitleY, width: width, height: subtitleHeight),
                    tools: toolsFrame,
                    height: subtitleY + subtitleHeight
                )
            }
        }

        let titleHeight = title.sizeThatFits(full).height
        let subtitleY = titleHeight + Self.subtitleSpacing
        var height = subtitleY + subtitleHeight
        var toolsFrame: CGRect?
        if let tools {
            let size = tools.sizeThatFits(full)
            let toolsWidth = min(size.width, width)
            toolsFrame = CGRect(x: width - toolsWidth, y: height + Self.rowSpacing, width: toolsWidth, height: size.height)
            height += Self.rowSpacing + size.height
        }
        return Arrangement(
            title: CGRect(x: 0, y: 0, width: width, height: titleHeight),
            subtitle: CGRect(x: 0, y: subtitleY, width: width, height: subtitleHeight),
            tools: toolsFrame,
            height: height
        )
    }
}

/// Keyboard shortcuts for the search while the picker is on top: ⌘F focuses the field
/// (scrolling it into view first), Escape (and ⌘.) clears it and leaves it. Invisible buttons,
/// so the shortcuts show in the list iPadOS displays while ⌘ is held.
struct PickerSearchShortcuts: View {
    let isActive: Bool
    @Binding var searchText: String
    var isSearchFocused: FocusState<Bool>.Binding
    let reveal: () -> Void

    var body: some View {
        let isSearching = isSearchFocused.wrappedValue || !searchText.isEmpty
        ZStack {
            Button("Search Albums") {
                reveal()
                isSearchFocused.wrappedValue = true
            }
            .keyboardShortcut(isActive ? KeyboardShortcut("f", modifiers: .command) : nil)
            Button("Clear Search") {
                searchText = ""
                isSearchFocused.wrappedValue = false
            }
            .keyboardShortcut(isActive && isSearching ? .cancelAction : nil)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// In place of the grid when no album title contains the search text.
struct NoMatchingAlbums: View {
    let query: String
    let clear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("No albums match “\(query)”")
                .font(.barTitle)
                .foregroundStyle(Palette.text)
                .lineLimit(2)
                .truncationMode(.middle)
            Text("Check the spelling, or clear the search to see every album.")
                .font(.lead)
                .foregroundStyle(Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            Button("Clear search", action: clear)
                .buttonStyle(.pill(.secondary))
                .fixedSize()
                .accessibilityIdentifier(A11yID.Picker.noMatchesClear)
                .padding(.top, 18)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11yID.Picker.noMatches)
    }
}
