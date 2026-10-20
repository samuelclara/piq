import SwiftUI
import XCTest
@testable import Piq

@MainActor
final class SwipeActionTests: XCTestCase {
    func testDeleteSwipesLeftAndKeepSwipesRight() {
        XCTAssertEqual(SwipeAction.delete.direction, .left)
        XCTAssertEqual(SwipeAction.keep.direction, .right)
        XCTAssertEqual(SwipeAction.Direction.left.sign, -1)
        XCTAssertEqual(SwipeAction.Direction.right.sign, 1)
    }

    func testEachDirectionIsBoundToTheActionThatOwnsIt() {
        XCTAssertEqual(SwipeAction.action(for: .left), .delete)
        XCTAssertEqual(SwipeAction.action(for: .right), .keep)
        for action in SwipeAction.allCases {
            XCTAssertEqual(SwipeAction.action(for: action.direction), action, "\(action)")
        }
    }

    func testOnlyDeleteMarksForDeletion() {
        XCTAssertTrue(SwipeAction.delete.marksForDeletion)
        XCTAssertFalse(SwipeAction.keep.marksForDeletion)
    }

    func testButtonTitlesPointTheWayThePhotoGoes() {
        XCTAssertEqual(SwipeAction.delete.buttonTitle, "\u{2190} Delete")
        XCTAssertEqual(SwipeAction.keep.buttonTitle, "Keep \u{2192}")
    }

    func testOnlyDeletingConfirmsWithAToast() {
        XCTAssertEqual(SwipeAction.delete.confirmationMessage, "Marked for deletion")
        XCTAssertNil(SwipeAction.keep.confirmationMessage)
    }

    func testTitlesAndStrokeStyleSymbols() {
        XCTAssertEqual(SwipeAction.allCases.map(\.title), ["Delete", "Keep"])
        XCTAssertEqual(SwipeAction.allCases.map(\.systemImage), ["trash", "checkmark"])
        XCTAssertFalse(SwipeAction.allCases.contains { $0.systemImage.hasSuffix(".fill") })
    }

    func testArrowKeysAndTintsFollowTheAction() {
        XCTAssertEqual(SwipeAction.delete.keyEquivalent.character, KeyEquivalent.leftArrow.character)
        XCTAssertEqual(SwipeAction.keep.keyEquivalent.character, KeyEquivalent.rightArrow.character)
        XCTAssertEqual(SwipeAction.delete.tint.base, Palette.coral)
        XCTAssertEqual(SwipeAction.keep.tint.base, Palette.sky)
        XCTAssertEqual(SwipeAction.delete.overlayColor, Palette.coral)
        XCTAssertEqual(SwipeAction.keep.overlayColor, Palette.sky)
    }

    func testDecisionsAreStoredUnderStableNames() {
        XCTAssertEqual(SwipeAction.delete.rawValue, "delete")
        XCTAssertEqual(SwipeAction.keep.rawValue, "keep")
    }
}
