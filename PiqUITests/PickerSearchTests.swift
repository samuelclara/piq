import XCTest

/// Searching the album picker by album name on the mock library (Recents, Favorites, Iceland
/// 2026, Weekend in Lisbon, Family, Drafts): typing filters the grid, the selection survives a
/// search that hides it, the clear buttons and the empty state, ⌘F and Escape (sent as ⌘.), Return
/// in the field, and the tools in portrait, Split View widths and at the largest text size.
@MainActor
final class PickerSearchTests: ExperienceTestCase {
    func testTypingFiltersTheGridAndKeepsTheSelection() {
        let app = launch(scenario: "resume")
        let field = searchField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.placeholderValue, "Search albums")
        XCTAssertTrue(app.buttons[ID.album("Iceland 2026")].isSelected)

        field.tap()
        field.typeText("lis")
        expectAlbums(["Weekend in Lisbon"], in: app)
        // The selected album is filtered out, but it stays selected: the bar still offers it.
        XCTAssertTrue(app.staticTexts["Selected: Iceland 2026"].exists)
        XCTAssertEqual(app.buttons[ID.start].label, "Resume, 38 of 400")
        shoot("picker-search-lis", app)

        clearField(field)
        field.typeText("ICE")
        expectAlbums(["Iceland 2026"], in: app)
        clearField(field)
        // Recents and Favorites are searched too.
        field.typeText("fav")
        expectAlbums(["Favorites"], in: app)
        clearField(field)
        field.typeText("  re  ")
        expectAlbums(["Recents"], in: app)

        app.buttons["picker.search.clear"].tap()
        expectAlbums(Self.photosOrder, in: app)
        XCTAssertTrue(app.buttons[ID.album("Iceland 2026")].isSelected)
        XCTAssertFalse(app.buttons["picker.search.clear"].exists, "No clear button without text")
        app.terminate()
    }

    func testNoMatchesShowsAMessageWithAWayBack() {
        let app = launch(scenario: "albums")
        let field = searchField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Kyoto")
        let message = element("picker.noMatches", in: app)
        XCTAssertTrue(message.waitForExistence(timeout: 3))
        XCTAssertTrue(labelled("No albums match “Kyoto”", in: app).exists)
        expectAlbums([], in: app)
        shoot("picker-search-no-matches", app)

        app.buttons["picker.noMatches.clear"].tap()
        XCTAssertTrue(message.waitForNonExistence(timeout: 3))
        expectAlbums(Self.photosOrder, in: app)
        XCTAssertEqual(field.value as? String, "Search albums", "The field is empty again (showing its placeholder)")
        app.terminate()
    }

    /// ⌘F puts the keyboard in the field (typed keys then filter), ⌘. (Escape's shortcut) clears
    /// and leaves it, after which Return starts sorting again. On sorting, ⌘F does nothing.
    func testCommandFFocusesTheFieldAndEscapeClearsIt() {
        let app = launch(scenario: "resume")
        XCTAssertTrue(searchField(app).waitForExistence(timeout: 5))
        wakeKeyboard(app)

        press("f", .command, in: app)
        XCTAssertTrue(waitForKeyboardFocus(searchField(app)), "⌘F focuses the search field")
        app.typeText("fam")
        expectAlbums(["Family"], in: app)
        shoot("picker-search-command-f", app)

        press(".", .command, in: app)
        expectAlbums(Self.photosOrder, in: app)
        XCTAssertFalse(hasKeyboardFocus(searchField(app)), "Escape leaves the field")
        XCTAssertEqual(searchField(app).value as? String, "Search albums")

        pressReturn(app)
        expectSorting(app, position: 38, total: 400, marked: 4)
        press("f", .command, in: app)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(searchField(app).exists, "⌘F doesn't reach the picker under sorting")
        expectSorting(app, position: 38, total: 400, marked: 4)
        app.terminate()
    }

    /// Return in the field ends the search (keyboard down, filter kept) and doesn't start
    /// sorting, even with a startable album selected; the next Return does.
    func testReturnInTheFieldEndsTheSearchWithoutStartingToSort() {
        let app = launch(scenario: "resume")
        let field = searchField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        wakeKeyboard(app)
        field.tap()
        field.typeText("ice")
        expectAlbums(["Iceland 2026"], in: app)
        pressReturn(app)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(app.scrollViews[ID.pickerGrid].exists, "Return in the field didn't start sorting")
        XCTAssertFalse(hasKeyboardFocus(field), "Return leaves the field")
        expectAlbums(["Iceland 2026"], in: app)
        XCTAssertEqual(field.value as? String, "ice", "the filter stays")

        pressReturn(app)
        expectSorting(app, position: 38, total: 400, marked: 4)
        app.buttons[ID.sortingBack].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 4))
        XCTAssertEqual(field.value as? String, "ice", "the search is still there back on the picker")
        app.terminate()
    }

    /// Tab moves the keyboard into the field (iPadOS does that for text fields) and out again,
    /// and never types a tab into it; Return then starts sorting as before.
    func testTabMovesInAndOutOfTheFieldWithoutTypingTabs() {
        let app = launch(scenario: "resume")
        let field = searchField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        wakeKeyboard(app)
        press(.tab, in: app)
        XCTAssertTrue(waitForKeyboardFocus(field), "Tab moves into the search field")
        press(.tab, in: app)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(hasKeyboardFocus(field), "Tab leaves the field")
        XCTAssertEqual(field.value as? String, "Search albums", "No tab was typed into the field")
        expectAlbums(Self.photosOrder, in: app)
        pressReturn(app)
        expectSorting(app, position: 38, total: 400, marked: 4)
        app.terminate()
    }

    func testPortraitAndLargestText() {
        var app = launch(scenario: "resume", orientation: .portrait)
        var field = searchField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let title = labelled("Which album are we sorting?", in: app)
        XCTAssertGreaterThan(field.frame.minY, title.frame.maxY, "In portrait the tools get their own row")
        field.tap()
        field.typeText("e")
        expectAlbums(["Recents", "Favorites", "Iceland 2026", "Weekend in Lisbon"], in: app)
        shoot("picker-search-portrait", app)
        app.terminate()

        app = launch(scenario: "resume", extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXL"])
        field = searchField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(field.frame.height, 44)
        XCTAssertTrue(field.isHittable)
        XCTAssertTrue(app.buttons["picker.sort"].isHittable)
        field.tap()
        field.typeText("lisbon")
        expectAlbums(["Weekend in Lisbon"], in: app)
        shoot("picker-search-xxl", app)
        app.terminate()
    }

    /// Split View widths: 3 columns (700pt) and 2 (500pt, 375pt).
    func testSplitViewWidths() {
        let app = launch(scenario: "resume")
        XCTAssertTrue(searchField(app).waitForExistence(timeout: 5))
        for width in [700.0, 500.0, 375.0] {
            resizeWindow(app, toWidth: width)
            let field = searchField(app)
            let sort = app.buttons["picker.sort"]
            let window = app.windows.firstMatch.frame
            XCTAssertTrue(field.isHittable, "search at \(width)")
            XCTAssertTrue(sort.isHittable, "sort at \(width)")
            XCTAssertLessThanOrEqual(sort.frame.maxX, window.maxX, "sort inside the window at \(width)")
            XCTAssertGreaterThan(field.frame.width, 150, "a usable field at \(width)")
            field.tap()
            field.typeText("a")
            // The simulator's on-screen keyboard covers the grid: Return ends the search and
            // puts the keyboard away.
            pressReturn(app)
            expectAlbums(["Favorites", "Iceland 2026", "Family", "Drafts"], in: app)
            shoot("picker-search", app)
            app.buttons["picker.search.clear"].tap()
            expectAlbums(Self.photosOrder, in: app)
        }
        app.terminate()
    }

    // MARK: Helpers

    static let photosOrder = ["Recents", "Favorites", "Iceland 2026", "Weekend in Lisbon", "Family", "Drafts"]

    private func searchField(_ app: XCUIApplication) -> XCUIElement {
        app.searchFields["picker.search"]
    }

    private func clearField(_ field: XCUIElement) {
        let clear = XCUIApplication().buttons["picker.search.clear"]
        if clear.exists { clear.tap() }
    }

    private func hasKeyboardFocus(_ element: XCUIElement) -> Bool {
        (element.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
    }

    private func waitForKeyboardFocus(_ element: XCUIElement) -> Bool {
        let deadline = Date().addingTimeInterval(4)
        repeat {
            if hasKeyboardFocus(element) { return true }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return false
    }
}

extension ExperienceTestCase {
    /// The album tiles on screen, in reading order (row by row). Read from one snapshot of the
    /// app: tiles a search removes can go between two separate queries.
    func albumTitlesInOrder(_ app: XCUIApplication) -> [String] {
        let prefix = "picker.album."
        guard let root = try? app.snapshot() else { return [] }
        var placed: [(title: String, frame: CGRect)] = []
        var pending = [root]
        while let element = pending.popLast() {
            if element.elementType == .button, element.identifier.hasPrefix(prefix) {
                placed.append((String(element.identifier.dropFirst(prefix.count)), element.frame))
            }
            pending += element.children
        }
        let ordered = placed.sorted { lhs, rhs in
            if abs(lhs.frame.minY - rhs.frame.minY) > 4 {
                return lhs.frame.minY < rhs.frame.minY
            }
            return lhs.frame.minX < rhs.frame.minX
        }
        return ordered.map(\.title)
    }

    /// Waits until the grid shows exactly `titles`, in that order.
    func expectAlbums(_ titles: [String], in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(4)
        var seen: [String] = []
        repeat {
            seen = albumTitlesInOrder(app)
            if seen == titles { return }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        XCTFail("Expected albums \(titles), got \(seen)", file: file, line: line)
    }
}
