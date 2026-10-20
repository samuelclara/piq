import XCTest
@testable import Piq

@MainActor
final class ToastCenterTests: XCTestCase {
    func testAToastShowsWithACheckmarkAndGoesAwayOnItsOwn() async {
        let toasts = ToastCenter()

        toasts.show("Marked for deletion", duration: .milliseconds(50))

        XCTAssertEqual(toasts.current?.message, "Marked for deletion")
        XCTAssertEqual(toasts.current?.systemImage, "checkmark")
        await pollUntil("the toast is dismissed") { toasts.current == nil }
    }

    func testANewToastReplacesTheOneOnScreen() throws {
        let toasts = ToastCenter()
        toasts.show("Marked for deletion")
        let first = try XCTUnwrap(toasts.current)

        toasts.show("22 photos moved to Recently Deleted", systemImage: nil)

        XCTAssertEqual(toasts.current?.message, "22 photos moved to Recently Deleted")
        XCTAssertNil(toasts.current?.systemImage)
        toasts.dismiss(first.id)
        XCTAssertNotNil(toasts.current, "dismissing the old toast leaves the new one up")
        toasts.dismiss()
        XCTAssertNil(toasts.current)
    }
}
