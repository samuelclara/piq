import XCTest
@testable import Piq

@MainActor
final class ReviewModelTests: XCTestCase {
    // MARK: Copy

    func testSummary() {
        XCTAssertEqual(ReviewCopy.summary(sorted: 400, total: 400), "All 400 photos sorted. Check what goes before emptying the trash.")
        XCTAssertEqual(ReviewCopy.summary(sorted: 120, total: 400), "120 of 400 sorted so far. Nothing is deleted until you empty the trash.")
        XCTAssertEqual(ReviewCopy.summary(sorted: 1, total: 1), "1 photo sorted. Check what goes before emptying the trash.")
        XCTAssertEqual(ReviewCopy.summary(sorted: 0, total: 1), "0 of 1 sorted so far. Nothing is deleted until you empty the trash.")
        XCTAssertEqual(ReviewCopy.summary(sorted: 0, total: 0), "All photos sorted. Check what goes before emptying the trash.")
        XCTAssertEqual(ReviewCopy.summary(sorted: 1204, total: 1204), "All \(1204.formatted()) photos sorted. Check what goes before emptying the trash.")
    }

    func testCountedCopy() {
        XCTAssertEqual(ReviewCopy.deleteTitle(22), "Delete 22 photos?")
        XCTAssertEqual(ReviewCopy.deleteTitle(1), "Delete 1 photo?")
        XCTAssertEqual(ReviewCopy.deleteButton(22), "Delete 22 photos")
        XCTAssertEqual(ReviewCopy.restoreButton(0), "Restore")
        XCTAssertEqual(ReviewCopy.restoreButton(3), "Restore 3")
        XCTAssertEqual(ReviewCopy.restored(3), "3 photos restored")
        XCTAssertEqual(ReviewCopy.restored(1), "1 photo restored")
    }

    func testDeletedToast() {
        XCTAssertEqual(ReviewCopy.deleted(count: 22, undeletable: 0), "22 photos moved to Recently Deleted")
        XCTAssertEqual(ReviewCopy.deleted(count: 1, undeletable: 0), "1 photo moved to Recently Deleted")
        XCTAssertEqual(ReviewCopy.deleted(count: 20, undeletable: 2), "20 photos moved to Recently Deleted · 2 couldn't be deleted")
        XCTAssertEqual(ReviewCopy.deleted(count: 0, undeletable: 3), "3 photos couldn't be deleted")
        XCTAssertNil(ReviewCopy.deleted(count: 0, undeletable: 0))
    }

    // MARK: Selection

    func testTogglingAndSelectingAll() {
        let model = ReviewModel()
        let trash: Set<String> = ["a", "b", "c"]
        model.toggle("a")
        model.toggle("b")
        model.toggle("a")
        XCTAssertEqual(model.selection, ["b"])
        XCTAssertFalse(model.isEverythingSelected(in: trash))

        model.toggleSelectAll(in: trash)
        XCTAssertEqual(model.selection, trash)
        XCTAssertTrue(model.isEverythingSelected(in: trash))

        model.toggleSelectAll(in: trash)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertFalse(model.isEverythingSelected(in: []), "an empty trash is never all selected")
    }

    func testSelectionFollowsTheTrash() {
        let model = ReviewModel(selection: ["a", "b"], isConfirmingDelete: true)
        model.trashChanged(to: ["b", "c"])
        XCTAssertEqual(model.selection, ["b"])
        XCTAssertTrue(model.isConfirmingDelete)

        model.trashChanged(to: [])
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertFalse(model.isConfirmingDelete, "nothing left to confirm")
    }

    /// A photo deleted in Photos (or taken out of the album) while its preview is open leaves the
    /// trash, and its preview closes; a change to other photos leaves the preview open.
    func testThePreviewClosesWhenItsPhotoLeavesTheTrash() {
        let model = ReviewModel()
        model.showPreview(of: "a")
        model.trashChanged(to: ["a", "c"])
        XCTAssertEqual(model.preview?.id, "a", "another photo left")

        model.trashChanged(to: ["c"])
        XCTAssertNil(model.preview)
    }

    // MARK: Session

    func testLoadsDetailsForTheTrash() async {
        let (app, session) = PreviewSupport.session(.review)
        let model = ReviewModel()
        await model.loadMetadata(for: session.state.markedInOrder, from: app.library)
        XCTAssertEqual(model.metadata.count, 50)
        XCTAssertEqual(model.metadata["mock-asset-0011"]?.filename, "IMG_4412.HEIC")
    }

    func testRestoringTakesTheSelectionOffTheList() {
        let (app, session) = PreviewSupport.session(.review)
        let model = ReviewModel(selection: Set(session.state.markedInOrder.prefix(3)))
        model.restoreSelection(in: session, toasts: app.toasts)
        XCTAssertEqual(session.state.markedCount, 47)
        XCTAssertEqual(session.state.keptCount, 353)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertEqual(app.toasts.current?.message, "3 photos restored")
    }

    func testEmptyingTheTrash() async {
        let (app, session) = PreviewSupport.session(.review)
        let model = ReviewModel(selection: [session.state.markedInOrder[0]])
        await model.emptyTrash(in: session, toasts: app.toasts)
        XCTAssertEqual(session.state.markedCount, 0)
        XCTAssertEqual(session.state.total, 350)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertEqual(app.toasts.current?.message, "50 photos moved to Recently Deleted")
        XCTAssertEqual(app.toasts.current?.systemImage, "checkmark")
    }

    func testDecliningTheSystemPromptChangesNothing() async throws {
        let app = PreviewSupport.appModel(.review, deletion: .cancel)
        let session = try XCTUnwrap(app.activeSession)
        let first = session.state.markedInOrder[0]
        let model = ReviewModel(selection: [first])
        await model.emptyTrash(in: session, toasts: app.toasts)
        XCTAssertEqual(session.state.markedCount, 50)
        XCTAssertEqual(model.selection, [first])
        XCTAssertNil(app.toasts.current)
    }

    /// A second "Delete" tap while the first request waits on the system prompt starts nothing,
    /// and so can't clear the selection the person then keeps by declining.
    func testASecondRequestWhileTheFirstIsPendingChangesNothing() async throws {
        let app = PreviewSupport.appModel(.review, deletion: .cancel)
        let session = try XCTUnwrap(app.activeSession)
        let first = session.state.markedInOrder[0]
        let model = ReviewModel(selection: [first])
        async let firstRequest: Void = model.emptyTrash(in: session, toasts: app.toasts)
        async let secondRequest: Void = model.emptyTrash(in: session, toasts: app.toasts)
        _ = await (firstRequest, secondRequest)
        XCTAssertEqual(model.selection, [first])
        XCTAssertEqual(session.state.markedCount, 50)
        XCTAssertNil(app.toasts.current)
    }

    func testFailedDeletionSaysSo() async throws {
        let app = PreviewSupport.appModel(.review, deletion: .fail)
        let session = try XCTUnwrap(app.activeSession)
        await ReviewModel().emptyTrash(in: session, toasts: app.toasts)
        XCTAssertEqual(session.state.markedCount, 50)
        XCTAssertEqual(app.toasts.current?.message, "Couldn't delete the photos")
        XCTAssertEqual(app.toasts.current?.systemImage, "exclamationmark.circle")
    }
}
