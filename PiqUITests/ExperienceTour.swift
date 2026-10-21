import XCTest

/// The whole app, walked the way a person uses it, on the mock library: pick an album, start,
/// sort with swipes, pills and keys, review, select and restore, empty the trash, go back to the
/// picker and its "Resume" label, then sort a small album to the end. Every step is checked
/// against SPEC.md's copy and attached as a screenshot, in landscape (the design), portrait and
/// window widths of 700, 600, 500 and 375 points.
///
///     xcodebuild test -project Piq.xcodeproj -scheme Piq \
///       -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' \
///       -only-testing:PiqUITests/ExperienceTour -resultBundlePath Tour.xcresult
///     xcrun xcresulttool export attachments --path Tour.xcresult --output-path Tour
final class ExperienceTour: ExperienceTestCase {
    /// Iceland 2026, sorted from its first photo: these are its first assets, oldest first.
    private func iceland(_ index: Int) -> String { String(format: "mock-asset-%04d", index) }

    func testLandscapeJourney() {
        journey(.landscapeLeft)
    }

    func testPortraitJourney() {
        journey(.portrait)
    }

    /// Sorting a whole album ends on Review by itself, which then goes back to the albums, where
    /// the album offers its review.
    func testSortingToTheEnd() {
        let app = launch(scenario: "albums")
        app.buttons[ID.album("Weekend in Lisbon")].tap()
        let start = app.buttons[ID.start]
        XCTAssertEqual(start.label, "Start sorting, 36 photos")
        start.tap()
        expectSorting(app, position: 1, total: 36, marked: 0)
        Thread.sleep(forTimeInterval: 1)
        wakeKeyboard(app)
        var marked = 0
        for position in 1...36 {
            let deletes = position % 6 == 0
            press(deletes ? .leftArrow : .rightArrow, in: app)
            if deletes { marked += 1 }
            if position < 36 {
                expectSorting(app, position: position + 1, total: 36, marked: marked)
            }
        }
        let summary = element(ID.summary, in: app)
        XCTAssertTrue(summary.waitForExistence(timeout: 4), "The last photo leads to Review")
        XCTAssertEqual(summary.label, "All 36 photos sorted. Check what goes before emptying the trash.")
        XCTAssertEqual(app.buttons[ID.reviewBack].label, "Albums")
        XCTAssertTrue(labelled("36 sorted", in: app).exists)
        XCTAssertTrue(labelled("30 kept", in: app).exists)
        XCTAssertTrue(labelled("6 to delete", in: app).exists)
        Thread.sleep(forTimeInterval: 0.8)
        shoot("tour-21-review-all-sorted", app)

        // The system's edge swipe doesn't go back to an empty sorting screen.
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: edge.withOffset(CGVector(dx: 500, dy: 0)))
        Thread.sleep(forTimeInterval: 1)
        shoot("tour-22-after-edge-swipe", app)
        if summary.exists {
            app.buttons[ID.reviewBack].tap()
        } else {
            XCTFail("An edge swipe left Review for the finished sorting screen")
            attachHierarchy("tour-22-after-edge-swipe", app)
            app.buttons[ID.sortingBack].tap()
        }
        XCTAssertTrue(app.scrollViews[ID.pickerGrid].waitForExistence(timeout: 4))
        XCTAssertEqual(app.buttons[ID.start].label, "Review, 6 photos marked")
        shoot("tour-23-picker-review-label", app)
        app.terminate()
    }

    /// Each width: the picker, sorting, review with a selection, the confirm card, the preview,
    /// the empty trash and the access states.
    func testWindowWidths() {
        for width in [700.0, 600, 500, 375] {
            var app = launch(scenario: "resume")
            resizeWindow(app, toWidth: width)
            shoot("width-01-picker", app)
            app.buttons[ID.start].tap()
            XCTAssertTrue(app.staticTexts[ID.counter].waitForExistence(timeout: 4))
            Thread.sleep(forTimeInterval: 1)
            shoot("width-02-sorting", app)
            app.buttons[ID.delete].tap()
            expectToast("Marked for deletion", in: app)
            shoot("width-03-sorting-toast", app)
            // Labelled pill or round icon with its badge, the Review button is one element.
            expectSorting(app, position: 39, total: 400, marked: 5)
            XCTAssertEqual(app.descendants(matching: .any).matching(identifier: ID.review).count, 1, "\(width) pt: one Review element")
            app.buttons[ID.review].tap()
            XCTAssertTrue(element(ID.summary, in: app).waitForExistence(timeout: 4))
            Thread.sleep(forTimeInterval: 0.8)
            shoot("width-04-review", app)
            element(ID.tile(iceland(11)), in: app).tap()
            shoot("width-05-review-selection", app)
            app.buttons[ID.emptyTrash].tap()
            XCTAssertTrue(app.buttons[ID.confirmDelete].waitForExistence(timeout: 3))
            Thread.sleep(forTimeInterval: 0.6)
            shoot("width-06-confirm", app)
            app.buttons[ID.cancelDelete].tap()
            XCTAssertTrue(app.buttons[ID.confirmDelete].waitForNonExistence(timeout: 3))
            element(ID.tile(iceland(11)), in: app).press(forDuration: 0.5)
            XCTAssertTrue(app.buttons[ID.closePreview].waitForExistence(timeout: 3))
            Thread.sleep(forTimeInterval: 1)
            shoot("width-07-preview", app)
            app.buttons[ID.closePreview].tap()
            app.terminate()

            // iPadOS doesn't always give a relaunched app its last window size.
            app = launch(scenario: "emptyTrash")
            resizeWindow(app, toWidth: width)
            shoot("width-08-empty-trash", app)
            app.terminate()

            for access in ["limited", "denied"] {
                app = launch(access: access)
                resizeWindow(app, toWidth: width)
                shoot("width-09-access-\(access)", app)
                app.terminate()
            }
        }
    }

    /// The largest text size the app allows (xxLarge, the root's Dynamic Type cap) at full
    /// width, in portrait and in a narrow window: every screen and state, for copy that gets cut.
    func testLargestText() {
        let xxLarge = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXL"]
        let layouts: [(UIDeviceOrientation, CGFloat?)] = [(.landscapeLeft, nil), (.portrait, nil), (.landscapeLeft, 375)]
        for (orientation, width) in layouts {
            var app = launch(scenario: "resume", orientation: orientation, extra: xxLarge)
            if let width { resizeWindow(app, toWidth: width) }
            shoot("xxl-01-picker", app)
            app.buttons[ID.start].tap()
            XCTAssertTrue(app.staticTexts[ID.counter].waitForExistence(timeout: 4))
            app.buttons[ID.delete].tap()
            expectToast("Marked for deletion", in: app)
            shoot("xxl-02-sorting", app)
            let sortingTitle = app.staticTexts["Iceland 2026"].frame
            app.buttons[ID.review].tap()
            XCTAssertTrue(element(ID.summary, in: app).waitForExistence(timeout: 4))
            element(ID.tile(iceland(11)), in: app).tap()
            Thread.sleep(forTimeInterval: 0.5)
            shoot("xxl-03-review", app)
            // Both top bars show the album name in full: their back buttons give way first.
            XCTAssertEqual(app.staticTexts["Iceland 2026"].frame.width, sortingTitle.width, accuracy: 1, "the album name in full on Review, as on sorting")
            XCTAssertEqual(app.buttons[ID.reviewBack].label, "Continue sorting")
            app.buttons[ID.emptyTrash].tap()
            XCTAssertTrue(app.buttons[ID.confirmDelete].waitForExistence(timeout: 3))
            Thread.sleep(forTimeInterval: 0.6)
            shoot("xxl-04-confirm", app)
            app.buttons[ID.cancelDelete].tap()
            XCTAssertTrue(app.buttons[ID.confirmDelete].waitForNonExistence(timeout: 3))
            element(ID.tile(iceland(11)), in: app).press(forDuration: 0.5)
            XCTAssertTrue(app.buttons[ID.closePreview].waitForExistence(timeout: 3))
            Thread.sleep(forTimeInterval: 1)
            shoot("xxl-05-preview", app)
            app.terminate()

            app = launch(scenario: "emptyTrash", orientation: orientation, extra: xxLarge)
            if let width { resizeWindow(app, toWidth: width) }
            shoot("xxl-06-empty-trash", app)
            app.terminate()
            for access in ["limited", "denied"] {
                app = launch(access: access, orientation: orientation, extra: xxLarge)
                if let width { resizeWindow(app, toWidth: width) }
                shoot("xxl-07-access-\(access)", app)
                app.terminate()
            }
        }
    }

    /// The access states the journey doesn't pass through, in both orientations.
    func testAccessStates() {
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            for access in ["limited", "denied", "restricted"] {
                let app = launch(access: access, orientation: orientation)
                switch access {
                case "limited":
                    XCTAssertTrue(app.buttons[ID.changeSelection].waitForExistence(timeout: 4))
                    XCTAssertTrue(app.staticTexts["Connected to Photos"].exists)
                    XCTAssertTrue(app.buttons[ID.album("Recents")].exists)
                    XCTAssertTrue(app.buttons[ID.album("Favorites")].exists)
                default:
                    XCTAssertTrue(app.buttons[ID.openSettings].waitForExistence(timeout: 4))
                    XCTAssertFalse(app.buttons[ID.start].exists)
                }
                shoot("access-\(access)", app)
                app.terminate()
            }
        }
    }

    /// Emptying the trash when the system prompt is declined, and when Photos fails.
    func testEmptyTrashOutcomes() {
        var app = launch(scenario: "review", extra: ["-PiqMockDeletion", "cancel"])
        app.buttons[ID.emptyTrash].tap()
        app.buttons[ID.confirmDelete].tap()
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertFalse(element(ID.toast, in: app).exists, "Declining the system prompt says nothing")
        XCTAssertTrue(labelled("50 to delete", in: app).exists, "and keeps the list")
        shoot("outcome-cancelled", app)
        app.terminate()

        app = launch(scenario: "review", extra: ["-PiqMockDeletion", "fail"])
        app.buttons[ID.emptyTrash].tap()
        app.buttons[ID.confirmDelete].tap()
        expectToast("Couldn't delete the photos", in: app)
        XCTAssertTrue(labelled("50 to delete", in: app).exists)
        shoot("outcome-failed", app)
        app.terminate()
    }

    // MARK: Journey

    private func journey(_ orientation: UIDeviceOrientation) {
        let app = launch(scenario: "albums", orientation: orientation)

        // 1. The picker
        let start = app.buttons[ID.start]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertTrue(labelled("Which album are we sorting?", in: app).exists)
        XCTAssertTrue(labelled("Piq shows each photo full screen. Swipe left to mark it for deletion, swipe right to keep it.", in: app).exists)
        XCTAssertTrue(app.staticTexts["Connected to Photos"].exists)
        XCTAssertEqual(start.label, "Start sorting")
        XCTAssertFalse(start.isEnabled)
        shoot("tour-01-picker", app)
        attachHierarchy("tour-01-picker", app)

        let icelandTile = app.buttons[ID.album("Iceland 2026")]
        XCTAssertEqual(icelandTile.label, "Iceland 2026, 400 photos")
        icelandTile.tap()
        XCTAssertTrue(icelandTile.isSelected)
        XCTAssertTrue(app.staticTexts["Selected: Iceland 2026"].exists)
        XCTAssertEqual(start.label, "Start sorting, 400 photos")
        shoot("tour-02-picker-selected", app)

        // 2. Sorting
        start.tap()
        expectSorting(app, position: 1, total: 400, marked: 0)
        XCTAssertEqual(app.buttons[ID.sortingBack].label, "Albums")
        XCTAssertFalse(app.buttons[ID.undo].isEnabled, "Nothing to undo yet")
        XCTAssertTrue(labelled("Swipe left to delete, right to keep", in: app).exists)
        XCTAssertEqual(app.buttons[ID.delete].label, "Delete")
        XCTAssertEqual(app.buttons[ID.keep].label, "Keep")
        Thread.sleep(forTimeInterval: 1)
        shoot("tour-03-sorting", app)
        attachHierarchy("tour-03-sorting", app)

        let photo = element(ID.photo, in: app)
        photo.swipeLeft()
        // The toast first: it's up for 2.2 seconds from the swipe.
        expectToast("Marked for deletion", in: app)
        shoot("tour-04-sorting-toast", app)
        expectSorting(app, position: 2, total: 400, marked: 1)

        app.buttons[ID.keep].tap()
        expectSorting(app, position: 3, total: 400, marked: 1)
        wakeKeyboard(app)
        press(.leftArrow, in: app)
        expectSorting(app, position: 4, total: 400, marked: 2)
        press(.rightArrow, in: app)
        expectSorting(app, position: 5, total: 400, marked: 2)
        press("z", .command, in: app)
        expectSorting(app, position: 4, total: 400, marked: 2)
        app.buttons[ID.delete].tap()
        expectSorting(app, position: 5, total: 400, marked: 3)
        app.buttons[ID.undo].tap()
        expectSorting(app, position: 4, total: 400, marked: 2)
        photo.swipeRight()
        expectSorting(app, position: 5, total: 400, marked: 2)
        press(.leftArrow, in: app)
        expectSorting(app, position: 6, total: 400, marked: 3)
        press(.rightArrow, in: app)
        expectSorting(app, position: 7, total: 400, marked: 3)
        press(.leftArrow, in: app)
        expectSorting(app, position: 8, total: 400, marked: 4)
        Thread.sleep(forTimeInterval: 2.6)
        shoot("tour-05-sorting-progress", app)

        // 3. Review, part-way
        app.buttons[ID.review].tap()
        let summary = element(ID.summary, in: app)
        XCTAssertTrue(summary.waitForExistence(timeout: 4))
        XCTAssertEqual(summary.label, "7 of 400 sorted so far. Nothing is deleted until you empty the trash.")
        XCTAssertEqual(app.buttons[ID.reviewBack].label, "Continue sorting")
        XCTAssertTrue(labelled("7 sorted", in: app).exists)
        XCTAssertTrue(labelled("3 kept", in: app).exists)
        XCTAssertTrue(labelled("4 to delete", in: app).exists)
        XCTAssertEqual(app.buttons[ID.selectAll].label, "Select all")
        XCTAssertFalse(app.buttons[ID.restore].isEnabled)
        Thread.sleep(forTimeInterval: 0.8)
        shoot("tour-06-review", app)
        attachHierarchy("tour-06-review", app)

        let restoredTile = element(ID.tile(iceland(2)), in: app)
        restoredTile.tap()
        XCTAssertTrue(restoredTile.isSelected)
        XCTAssertEqual(app.buttons[ID.restore].label, "Restore 1 photo")
        shoot("tour-07-review-selected", app)
        app.buttons[ID.restore].tap()
        expectToast("1 photo restored", in: app)
        XCTAssertTrue(restoredTile.waitForNonExistence(timeout: 3))
        XCTAssertTrue(labelled("4 kept", in: app).exists)
        XCTAssertTrue(labelled("3 to delete", in: app).exists)
        shoot("tour-08-review-restored", app)

        app.buttons[ID.selectAll].tap()
        XCTAssertEqual(app.buttons[ID.selectAll].label, "Deselect all")
        XCTAssertEqual(app.buttons[ID.restore].label, "Restore 3 photos")
        shoot("tour-09-review-all-selected", app)
        app.buttons[ID.selectAll].tap()
        XCTAssertEqual(app.buttons[ID.selectAll].label, "Select all")

        element(ID.tile(iceland(4)), in: app).press(forDuration: 0.5)
        let close = app.buttons[ID.closePreview]
        XCTAssertTrue(close.waitForExistence(timeout: 3), "A long press opens the preview")
        Thread.sleep(forTimeInterval: 1)
        shoot("tour-10-preview", app)
        attachHierarchy("tour-10-preview", app)
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 3))

        // 4. Emptying the trash
        app.buttons[ID.emptyTrash].tap()
        let confirm = app.buttons[ID.confirmDelete]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        XCTAssertEqual(confirm.label, "Delete 3 photos")
        XCTAssertTrue(labelled("Delete 3 photos?", in: app).exists)
        XCTAssertTrue(labelled("They move to Recently Deleted in Photos, where you can still recover them for 30 days. You'll be asked to confirm once more.", in: app).exists)
        XCTAssertEqual(app.buttons[ID.cancelDelete].label, "Cancel")
        Thread.sleep(forTimeInterval: 0.6)
        shoot("tour-11-confirm", app)
        attachHierarchy("tour-11-confirm", app)
        confirm.tap()
        expectToast("3 photos moved to Recently Deleted", in: app)
        XCTAssertTrue(element(ID.emptyState, in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(labelled("Trash is empty", in: app).exists)
        XCTAssertTrue(labelled("Swipe a photo left while sorting to mark it for deletion. Nothing leaves Photos until you empty the trash.", in: app).exists)
        XCTAssertEqual(summary.label, "4 of 397 sorted so far. Nothing is deleted until you empty the trash.")
        shoot("tour-12-trash-emptied", app)
        attachHierarchy("tour-12-trash-emptied", app)

        // 5. Back to sorting, then to the picker
        let emptyStateButton = app.buttons[ID.emptyStateButton]
        XCTAssertEqual(emptyStateButton.label, "Continue sorting")
        emptyStateButton.tap()
        expectSorting(app, position: 5, total: 397, marked: 0)
        Thread.sleep(forTimeInterval: 0.8)
        shoot("tour-13-sorting-again", app)
        app.buttons[ID.sortingBack].tap()
        XCTAssertTrue(start.waitForExistence(timeout: 4))
        XCTAssertEqual(start.label, "Resume, 5 of 397")
        XCTAssertTrue(app.buttons[ID.album("Iceland 2026")].isSelected)
        XCTAssertEqual(app.buttons[ID.album("Iceland 2026")].label, "Iceland 2026, 397 photos")
        Thread.sleep(forTimeInterval: 0.6)
        shoot("tour-14-picker-resume", app)
        app.terminate()
    }
}
