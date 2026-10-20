import XCTest
@testable import Piq

/// The album picker's start button title for each kind of saved session.
@MainActor
final class AlbumPickerTests: XCTestCase {
    private let album = AlbumSummary(id: "album", title: "Iceland 2026", kind: .user, photoCount: 400, coverAssetID: nil)

    func testTitleWithoutASession() {
        XCTAssertEqual(PickerBottomBar.startTitle(for: nil, resume: nil), "Start sorting")
        XCTAssertEqual(PickerBottomBar.startTitle(for: album, resume: nil), "Start sorting · 400 photos")
    }

    func testUnfinishedSessionResumesAtItsPhoto() {
        let lastPhotoLeft = ResumePoint(position: 400, total: 400, markedCount: 49, isComplete: false)
        XCTAssertEqual(PickerBottomBar.startTitle(for: album, resume: lastPhotoLeft), "Resume · 400 of 400")
        XCTAssertEqual(title(PreviewSupport.appModel(.resume)), "Resume · 38 of 400")
    }

    /// Everything sorted with photos still in Piq's trash: the button opens the review screen,
    /// so it says so instead of "Resume · 400 of 400".
    func testFinishedSessionWithMarkedPhotosOffersReview() {
        let onePhoto = ResumePoint(position: 400, total: 400, markedCount: 1, isComplete: true)
        XCTAssertEqual(PickerBottomBar.startTitle(for: album, resume: onePhoto), "Review · 1 photo marked")
        XCTAssertEqual(title(PreviewSupport.appModel(.review)), "Review · 50 photos marked")
    }

    private func title(_ app: AppModel) -> String {
        let album = app.selectedAlbum
        return PickerBottomBar.startTitle(for: album, resume: album.flatMap { app.resumePoint(for: $0.id) })
    }
}
