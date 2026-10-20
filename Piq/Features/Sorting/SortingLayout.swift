import SwiftUI

/// Sizes on the sorting screen, worked out from the space the window gives it: the designed
/// landscape layout at 1194×834, scaled for portrait, Split View and small windows. (The top bar
/// fits its labels itself; see `SortingBarFit`.)
enum SortingLayout {
    /// Gap between the Delete and Keep pills.
    static let actionSpacing: CGFloat = 16
    /// Space between the top bar and the photo.
    static let stageTopInset: CGFloat = 18
    /// Space under the photo: the next photo peeks out 18pt below it, then some air.
    static let stageBottomInset: CGFloat = 34

    /// Width of each Delete / Keep pill in a window `width` wide.
    static func actionButtonWidth(forWidth width: CGFloat) -> CGFloat {
        let margin = Metrics.pageMargin(forWidth: width)
        return max(0, min(200, (width - 2 * margin - actionSpacing) / 2))
    }

    /// The box the current photo is fitted into (aspect-fit), about 900×560 at 1194×834.
    ///
    /// A wide stage keeps air on both sides, about 0.76 of its width as in the design; a tall one
    /// (portrait, Split View) uses the full width minus the page margins. In between, the two
    /// blend, so resizing a window never makes the photo jump.
    static func photoBox(in stage: CGSize) -> CGSize {
        let height = stage.height - stageTopInset - stageBottomInset
        let fullWidth = stage.width - 2 * Metrics.pageMargin(forWidth: stage.width)
        let airyWidth = min(fullWidth, stage.width * 0.76)
        let aspect = stage.height > 0 ? stage.width / stage.height : 1
        let wideness = min(max((aspect - 1) / 0.6, 0), 1)
        let width = fullWidth + (airyWidth - fullWidth) * wideness
        return CGSize(width: max(width, 0), height: max(height, 0))
    }
}
