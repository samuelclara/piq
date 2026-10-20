import Foundation

/// What Piq does with the photo on screen. Each case owns its swipe direction, so adding an
/// action later (say, turning the right swipe into "edit") means adding a case here and
/// handling it in `SortingState.apply(_:)`; the gesture, buttons, keys and VoiceOver actions
/// all read from this enum.
enum SwipeAction: String, Codable, CaseIterable, Sendable {
    case delete
    case keep

    enum Direction: Sendable {
        case left
        case right

        /// -1 for left, +1 for right.
        var sign: Double { self == .left ? -1 : 1 }
    }

    /// The action bound to a swipe in `direction`.
    static func action(for direction: Direction) -> SwipeAction {
        switch direction {
        case .left: .delete
        case .right: .keep
        }
    }

    var direction: Direction {
        switch self {
        case .delete: .left
        case .keep: .right
        }
    }

    /// Verb shown on the swipe overlay and used as the VoiceOver action name.
    var title: String {
        switch self {
        case .delete: "Delete"
        case .keep: "Keep"
        }
    }

    /// Stroke-style SF Symbol for the overlay.
    var systemImage: String {
        switch self {
        case .delete: "trash"
        case .keep: "checkmark"
        }
    }

    /// Whether this decision puts the photo in Piq's trash.
    var marksForDeletion: Bool { self == .delete }

    /// Toast shown after the decision, if any.
    var confirmationMessage: String? {
        switch self {
        case .delete: "Marked for deletion"
        case .keep: nil
        }
    }
}
