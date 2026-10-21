import XCTest

/// Sorting the album picker on the mock library: the Sort menu and its two orders, Recents and
/// Favorites pinned first, sorting and searching together, the choice kept across launches, and
/// no Sort under limited access. The mock albums were made Family, Iceland 2026, Weekend in
/// Lisbon, then Drafts, so "Date created" lists Drafts first (made last, though empty) and Family
/// last (made first, though it holds the newest photos).
///
/// The order is kept in Piq's user defaults on the simulator, so every test that changes it puts
/// Photos order back when it ends, pass or fail.
@MainActor
final class PickerSortTests: ExperienceTestCase {
    static let photosOrder = ["Recents", "Favorites", "Iceland 2026", "Weekend in Lisbon", "Family", "Drafts"]
    static let dateCreatedOrder = ["Recents", "Favorites", "Drafts", "Weekend in Lisbon", "Iceland 2026", "Family"]

    func testDateCreatedOrderIsKeptAcrossLaunches() {
        restorePhotosOrderAtTheEnd()
        var app = launch(scenario: "resume")
        let sort = app.buttons["picker.sort"]
        XCTAssertTrue(sort.waitForExistence(timeout: 5))
        XCTAssertEqual(sort.label, "Sort albums")
        XCTAssertEqual(sort.value as? String, "Photos order")
        expectAlbums(Self.photosOrder, in: app)

        choose("Date created", in: app)
        expectAlbums(Self.dateCreatedOrder, in: app)
        XCTAssertEqual(sort.value as? String, "Date created")
        XCTAssertTrue(app.buttons[ID.album("Iceland 2026")].isSelected, "Sorting keeps the selection")
        shoot("picker-sorted-date-created", app)

        sort.tap()
        let current = app.buttons["Date created"]
        XCTAssertTrue(current.waitForExistence(timeout: 3))
        XCTAssertTrue(current.isSelected, "The menu checks the current order")
        XCTAssertTrue(app.buttons["Photos order"].exists)
        shoot("picker-sort-menu", app)
        dismissMenu(app)
        app.terminate()

        app = launch(scenario: "resume")
        XCTAssertTrue(app.buttons["picker.sort"].waitForExistence(timeout: 5))
        expectAlbums(Self.dateCreatedOrder, in: app)
        XCTAssertEqual(app.buttons["picker.sort"].value as? String, "Date created", "The order is kept across launches")

        choose("Photos order", in: app)
        expectAlbums(Self.photosOrder, in: app)
        app.terminate()

        app = launch(scenario: "resume")
        XCTAssertTrue(app.buttons["picker.sort"].waitForExistence(timeout: 5))
        expectAlbums(Self.photosOrder, in: app)
        app.terminate()
    }

    func testSortingAndSearchingTogether() {
        restorePhotosOrderAtTheEnd()
        let app = launch(scenario: "albums", orientation: .portrait)
        XCTAssertTrue(app.buttons["picker.sort"].waitForExistence(timeout: 5))
        choose("Date created", in: app)
        let field = app.searchFields["picker.search"]
        field.tap()
        field.typeText("i")
        // "i" is in Favorites, Iceland 2026, Weekend in Lisbon and Family; Recents and Favorites
        // stay first, the rest the album made last first.
        expectAlbums(["Favorites", "Weekend in Lisbon", "Iceland 2026", "Family"], in: app)
        shoot("picker-sorted-and-searched", app)
        app.terminate()
    }

    /// Under limited access Piq lists Recents and Favorites only, which never move: no Sort, but
    /// the search is there.
    func testNoSortUnderLimitedAccess() {
        let app = launch(access: "limited")
        XCTAssertTrue(app.searchFields["picker.search"].waitForExistence(timeout: 5))
        expectAlbums(["Recents", "Favorites"], in: app)
        XCTAssertFalse(app.buttons["picker.sort"].exists)
        shoot("picker-limited-no-sort", app)
        app.terminate()
    }

    // MARK: Helpers

    private func choose(_ order: String, in app: XCUIApplication) {
        app.buttons["picker.sort"].tap()
        let item = app.buttons[order]
        XCTAssertTrue(item.waitForExistence(timeout: 3), "The Sort menu offers \(order)")
        item.tap()
        XCTAssertTrue(item.waitForNonExistence(timeout: 3), "Choosing closes the menu")
    }

    private func dismissMenu(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.95)).tap()
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// Puts Photos order back in Piq's user defaults when the test ends.
    private func restorePhotosOrderAtTheEnd() {
        addTeardownBlock { @MainActor in
            let app = XCUIApplication()
            app.launchArguments = ["-PiqMockLibrary"]
            app.launch()
            let sort = app.buttons["picker.sort"]
            if sort.waitForExistence(timeout: 5), sort.value as? String != "Photos order" {
                sort.tap()
                let item = app.buttons["Photos order"]
                if item.waitForExistence(timeout: 3) { item.tap() }
                Thread.sleep(forTimeInterval: 0.5)
            }
            XCTAssertEqual(sort.value as? String, "Photos order", "Photos order is back for the tests that follow")
            app.terminate()
        }
    }
}
