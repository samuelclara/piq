import SwiftUI

/// Geometry of the album picker for a window width: 4 columns in landscape, 3 in portrait and 2
/// in narrow Split View, with covers 172pt tall at full width and proportional below that.
struct PickerLayout {
    let width: CGFloat

    /// Space between the header and the title.
    static let introTopPadding: CGFloat = 6
    /// Space between the intro (or the limited-access notice) and the grid.
    static let gridTopPadding: CGFloat = 28
    /// Space under the last row, above the bottom bar. With the paddings above, two rows fit a
    /// landscape window (834pt tall) without scrolling.
    static let gridBottomPadding: CGFloat = 20

    var margin: CGFloat { Metrics.pageMargin(forWidth: width) }

    var columns: Int { Metrics.albumColumns(forWidth: width) }

    /// Space between tiles in a row; never wider than the page margin.
    var columnSpacing: CGFloat { min(20, margin) }

    /// Space between rows: a little more than between columns, so each title and count stays
    /// with its own cover.
    var rowSpacing: CGFloat { columnSpacing + 4 }

    var tileWidth: CGFloat {
        let count = CGFloat(columns)
        return max(0, (width - 2 * margin - (count - 1) * columnSpacing) / count)
    }

    /// 172pt in the 4-column landscape layout, about 0.65 × the tile width when tiles are narrower.
    var coverHeight: CGFloat {
        min(Metrics.albumCoverHeight, (tileWidth * 0.66).rounded())
    }

    var coverSize: CGSize { CGSize(width: tileWidth, height: coverHeight) }

    var gridItems: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: columnSpacing, alignment: .top), count: columns)
    }

    /// Narrow windows stack what sits side by side elsewhere: the selection above a full-width
    /// start button, and "Change selection" under the limited-access message.
    var isNarrow: Bool { width < 560 }
}
