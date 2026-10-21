import Photos
import XCTest

/// Piq on the simulator's real photo library: launched without `-PiqMockLibrary` (with
/// `-PiqInMemoryStore`, so every launch starts without saved sessions). Covers the album picker,
/// sorting "E2E Trip" in capture order with sharp photos, emptying the trash through the iPadOS
/// confirmation (both answers), photos deleted from the library and taken out of the album
/// outside Piq while it is sorted, and the first-launch authorization prompt (Allow Full Access,
/// Don't Allow, Limit Access).
///
/// Gated: runs only with `TEST_RUNNER_PIQ_E2E=1`, on a simulator prepared as described on
/// `PiqTests/PhotoKitIntegrationTests`. `Tools/PhotoKitE2E/run-e2e.sh` runs every step in order,
/// shell steps included, and fails when any test fails or skips:
///
/// 1. `Tools/PhotoKitE2E/prepare-library.sh` imports the media (and re-imports the photos earlier
///    runs deleted).
/// 2. `test00GrantFullAccess` resets Piq's Photos permission and answers its prompt with Allow
///    Full Access, gives this test runner full access too (it changes the library "outside Piq"
///    and checks Piq's answers against PhotoKit), and hides E2E_1056 once. `xcrun simctl privacy
///    grant photos` is not enough on iOS 26.5: PhotoKit still reports notDetermined.
/// 3. `PiqTests/PhotoKitIntegrationTests/test00PrepareLibrary` arranges the albums and favorites.
/// 4. This class. The trash test and the deletion test each move 2 of E2E Trip's photos to
///    Recently Deleted; steps 1 and 3 put E2E Trip back to 25 photos (the script runs them again
///    when it ends).
///
/// Past the gate nothing skips: a missing prompt, a runner without access or an unprepared
/// library fails the test. The authorization tests reset Piq's Photos permission themselves
/// (`XCUIApplication.resetAuthorizationStatus(for: .photos)`) and grant full access again when
/// they finish.
///
/// What iPadOS shows, as XCUITest sees it (iOS 26.5):
/// - The Photos permission prompt (Limit Access…, Allow Full Access, Don’t Allow) and the
///   "Allow “Piq” to delete N photos?" confirmation (Don’t Allow, Delete) are SpringBoard alerts
///   (`XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts`), not part of Piq's
///   hierarchy. Declining the deletion reaches Piq as PHPhotosErrorDomain 3072.
/// - The limited-library picker (after Limit Access…, and from Change selection) is a popover
///   bridged into Piq's own hierarchy: its photos are images identified `PXGGridLayout-Info`
///   ("Photo, 11 October, 19:07", newest first) that report `isHittable == false`, so they are
///   tapped by coordinate; Done is the button identified `Update`.
/// - XCUITest's waits block the main actor, so a PhotoKit request made from a main-actor `Task`
///   doesn't even start until the wait ends (that is how this runner's own access prompt once
///   came up only after a 40 s wait, with nothing left to answer it). This process's requests
///   use PhotoKit's completion handlers, which start at once, and every wait has a deadline.
/// - The deletion test deletes from this process with Piq in the background, as when the person
///   deletes the photos in Photos and comes back; the confirmation ("Allow “PiqUITests-Runner”
///   to delete 2 photos?") is a SpringBoard alert too.
@MainActor
final class PhotoKitEndToEndTests: XCTestCase {
    private enum ID {
        static func album(_ title: String) -> String { "picker.album.\(title)" }
        static func tile(_ assetID: String) -> String { "review.tile.\(assetID)" }
        static let start = "picker.start"
        static let openSettings = "picker.openSettings"
        static let changeSelection = "picker.changeSelection"
        static let back = "sorting.back"
        static let counter = "sorting.counter"
        static let undo = "sorting.undo"
        static let review = "sorting.review"
        static let photo = "sorting.photo"
        static let delete = "sorting.delete"
        static let keep = "sorting.keep"
        static let next = "sorting.next"
        static let reviewBack = "review.back"
        static let summary = "review.summary"
        static let emptyTrash = "review.emptyTrash"
        static let confirmDelete = "review.confirmDelete"
        static let emptyState = "review.emptyState"
        static let toast = "toast"
    }

    private static let trip = "E2E Trip"
    private static let hiddenPhoto = "E2E_1056.JPG"
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    // MARK: Setup

    /// Gives Piq full Photos access by answering its real prompt (from whatever an earlier run
    /// left: an interrupted first-launch test can leave it denied or limited), gives this test
    /// runner full access as well, and hides E2E_1056.
    func test00GrantFullAccess() throws {
        try requireE2E()
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .photos)
        launch(app)
        let recents = app.buttons[ID.album("Recents")]
        guard answerPrompts(tapping: ["Allow Full Access"], until: { recents.exists }, timeout: 60) else {
            attachHierarchy("grant-piq-app", app)
            attachHierarchy("grant-piq-springboard", springboard)
            attachScreenshot("grant-piq")
            XCTFail("Piq doesn't list the albums 60 s after launching with its Photos permission reset")
            throw RecordedFailure()
        }
        app.terminate()

        if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined {
            let status = PhotoKitAnswer<PHAuthorizationStatus>()
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { @Sendable answer in status.resolve(answer) }
            guard answerPrompts(tapping: ["Allow Full Access"], until: { status.value != nil }, timeout: 120) else {
                attachHierarchy("grant-runner-springboard", springboard)
                attachScreenshot("grant-runner")
                XCTFail("This test runner's Photos prompt wasn't answered within 120 s")
                throw RecordedFailure()
            }
        }
        let runner = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard runner == .authorized else {
            let bundleID = Bundle.main.bundleIdentifier ?? "<runner bundle id>"
            XCTFail("The test runner has Photos access \(runner.rawValue), not full access: xcrun simctl privacy <SIM> reset photos \(bundleID), then run this test again")
            throw RecordedFailure()
        }

        // A hidden photo, E2E_1056. Hiding asks for confirmation ("Allow … to hide this
        // photo?"), which a hosted unit test can't answer, so it's done here, once, while Piq
        // isn't in front.
        for (assetID, filename, isHidden) in Self.e2ePhotosHiddenState() where filename == Self.hiddenPhoto && !isHidden {
            let change = Self.change {
                let options = PHFetchOptions()
                options.includeHiddenAssets = true
                guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: options).firstObject else { return }
                PHAssetChangeRequest(for: asset).isHidden = true
            }
            try finish(change, answering: ["Hide", "Allow"], "hiding \(filename)")
            // iOS 26 locks the Hidden album: PhotoKit stops showing the photo to apps at all.
            XCTAssertFalse(Self.e2ePhotosHiddenState().contains { $0.0 == assetID }, "a hidden photo is invisible to apps")
        }
    }

    // MARK: Album picker

    func testThePickerListsTheRealAlbumsWithCoversAndPhotoCounts() throws {
        try requireE2E()
        let library = try Oracle()
        let app = launch()
        waitForAlbums(app)
        XCTAssertTrue(app.staticTexts["Connected to Photos"].exists)

        let recents = app.buttons[ID.album("Recents")]
        let favorites = app.buttons[ID.album("Favorites")]
        let trip = app.buttons[ID.album(Self.trip)]
        let empty = app.buttons[ID.album("E2E Empty")]
        let nested = app.buttons[ID.album("E2E Nested")]
        for tile in [recents, favorites, trip, empty, nested] {
            XCTAssertTrue(tile.waitForExistence(timeout: 5), tile.identifier)
        }
        // Counts as PhotoKit has them (photos only), read from this test process.
        XCTAssertEqual(recents.label, "Recents, \(library.photos(in: .smartAlbumUserLibrary).count) photos")
        XCTAssertEqual(favorites.label, "Favorites, \(library.photos(in: .smartAlbumFavorites).count) photos", "the favorite video isn't counted")
        XCTAssertEqual(trip.label, "E2E Trip, \(library.tripPhotos.count) photos")
        XCTAssertEqual(empty.label, "E2E Empty, 0 photos", "only a video")
        XCTAssertEqual(nested.label, "E2E Nested, 5 photos", "the album inside E2E Folder")

        // Recents, Favorites, then the albums in Photos' order (E2E Folder's album in its place).
        let order = [recents, favorites, trip, empty, nested].map(\.frame)
        for (earlier, later) in zip(order, order.dropFirst()) {
            XCTAssertTrue(earlier.minY < later.minY - 1 || (abs(earlier.minY - later.minY) <= 1 && earlier.minX < later.minX), "reading order: \(earlier) before \(later)")
        }
        attachScreenshot("e2e-picker")

        let start = app.buttons[ID.start]
        empty.tap()
        waitForLabel(start, "Start sorting · 0 photos")
        XCTAssertFalse(start.isEnabled, "nothing to sort in an album without photos")
        trip.tap()
        waitForLabel(start, "Start sorting · \(library.tripPhotos.count) photos")
        XCTAssertTrue(start.isEnabled)
        XCTAssertTrue(trip.isSelected)
        attachScreenshot("e2e-picker-selected")
    }

    // MARK: Sorting

    func testSortingTheTripShowsSharpPhotosInCaptureOrderWithSwipesKeysAndUndo() throws {
        try requireE2E()
        let library = try Oracle()
        let expected = library.tripPhotos.map(\.filename)
        let total = expected.count
        let app = launch()
        openTrip(app, count: total)
        expect(app, position: 1, total: total, marked: 0)

        var seen = [try currentPhoto(app)]
        try expectSharp(app, "e2e-sorting-first")
        wakeKeyboard(app)

        // → keeps, three times.
        for position in 2...4 {
            press(.rightArrow, in: app)
            expect(app, position: position, total: total, marked: 0)
            seen.append(try currentPhoto(app))
        }
        try expectSharp(app, "e2e-sorting-4")

        // Swipe left on the 4th photo: marked. The toast lives 2.2 s, and under load `swipeLeft()`
        // only returns 1.5–2.9 s after the swipe (it waits for the app to go idle), so whether
        // the toast is still up is down to timing; SortingFlowTests requires it. Here its text
        // is checked whenever it is caught.
        photo(in: app).swipeLeft()
        let toast = app.descendants(matching: .any)[ID.toast]
        if toast.exists {
            XCTAssertTrue(toast.label.contains("Marked for deletion"), toast.label)
        } else {
            print("The toast was gone before swipeLeft() returned")
        }
        expect(app, position: 5, total: total, marked: 1)
        seen.append(try currentPhoto(app))

        // ← deletes, swipe right keeps, the pills do the same.
        press(.leftArrow, in: app)
        expect(app, position: 6, total: total, marked: 2)
        seen.append(try currentPhoto(app))
        photo(in: app).swipeRight()
        expect(app, position: 7, total: total, marked: 2)
        seen.append(try currentPhoto(app))
        app.buttons[ID.delete].tap()
        expect(app, position: 8, total: total, marked: 3)
        seen.append(try currentPhoto(app))
        app.buttons[ID.keep].tap()
        expect(app, position: 9, total: total, marked: 3)
        seen.append(try currentPhoto(app))

        // Capture order: the album's photos oldest first, as PhotoKit dates them.
        XCTAssertEqual(seen.map(\.filename), Array(expected.prefix(9)))
        let dates = try seen.map { try XCTUnwrap(E2EMedia.captureDate(of: $0.filename), $0.filename) }
        XCTAssertTrue(zip(dates, dates.dropFirst()).allSatisfy { $0 < $1 }, "capture order: \(seen.map(\.filename))")

        // ⌘Z and the Undo button step back, reversing the decisions.
        app.windows.firstMatch.typeKey("z", modifierFlags: .command)
        expect(app, position: 8, total: total, marked: 3)
        XCTAssertEqual(try currentPhoto(app), seen[7])
        app.buttons[ID.undo].tap()
        expect(app, position: 7, total: total, marked: 2)
        XCTAssertEqual(try currentPhoto(app), seen[6])
        try expectSharp(app, "e2e-sorting-after-undo")

        // Review: the 2 marked photos (the 4th and 5th), each named in its tile's label.
        app.buttons[ID.review].tap()
        let summary = app.staticTexts[ID.summary]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertEqual(summary.label, "6 of \(total) sorted so far. Nothing is deleted until you empty the trash.")
        let marked = try [seen[3], seen[4]].map { shown in
            try XCTUnwrap(library.tripPhotos.first { $0.filename == shown.filename }, shown.filename)
        }
        XCTAssertEqual(Set(reviewTiles(app).allElementsBoundByIndex.map(\.identifier)), Set(marked.map { ID.tile($0.id) }))
        for photo in marked {
            waitForLabel(app.descendants(matching: .any)[ID.tile(photo.id)], containing: photo.filename)
        }
        attachScreenshot("e2e-review")
    }

    // MARK: Emptying the trash

    /// Piq's confirmation card, then the iPadOS one. Declining leaves the trash as it was, with no
    /// toast; accepting moves the photos to Recently Deleted and E2E Trip loses them.
    func testEmptyingTheTrashGoesThroughPhotosConfirmationBothWays() throws {
        try requireE2E()
        let total = try Oracle().tripPhotos.count
        let app = launch()
        openTrip(app, count: total)
        wakeKeyboard(app)
        press(.leftArrow, in: app)
        expect(app, position: 2, total: total, marked: 1)
        press(.leftArrow, in: app)
        expect(app, position: 3, total: total, marked: 2)
        app.buttons[ID.review].tap()
        XCTAssertEqual(reviewTiles(app).count, 2)

        // Declined.
        try confirmEmptyTrash(app, count: 2)
        let prompt = try systemPrompt(containing: "Delete", "e2e-delete-prompt")
        attachScreenshot("e2e-delete-prompt")
        try button(in: prompt, oneOf: ["Don’t Allow", "Don't Allow", "Cancel"]).tap()
        XCTAssertTrue(prompt.waitForNonExistence(timeout: 5))
        let toast = app.descendants(matching: .any)[ID.toast]
        XCTAssertFalse(toast.waitForExistence(timeout: 2.5), "no toast when the person declines")
        XCTAssertEqual(reviewTiles(app).count, 2, "the trash is unchanged")
        XCTAssertTrue(app.buttons[ID.emptyTrash].isHittable)
        attachScreenshot("e2e-delete-declined")

        // Accepted.
        try confirmEmptyTrash(app, count: 2)
        let again = try systemPrompt(containing: "Delete", "e2e-delete-prompt-2")
        try button(in: again, oneOf: ["Delete"]).tap()
        XCTAssertTrue(toast.waitForExistence(timeout: 10), "a toast once Photos has deleted them")
        XCTAssertTrue(toast.label.contains("2 photos moved to Recently Deleted"), toast.label)
        XCTAssertTrue(app.descendants(matching: .any)[ID.emptyState].waitForExistence(timeout: 5), "the trash is empty")
        XCTAssertEqual(reviewTiles(app).count, 0)
        attachScreenshot("e2e-deleted")

        // The album lost the 2 photos: the session and the picker say so, and so does PhotoKit.
        app.buttons[ID.reviewBack].tap()
        expect(app, position: 1, total: total - 2, marked: 0)
        app.buttons[ID.back].tap()
        let trip = app.buttons[ID.album(Self.trip)]
        XCTAssertTrue(trip.waitForExistence(timeout: 5))
        waitForLabel(trip, "E2E Trip, \(total - 2) photos")
        XCTAssertEqual(try Oracle().tripPhotos.count, total - 2)
        attachScreenshot("e2e-picker-after-delete")
    }

    // MARK: Changes outside Piq

    /// While E2E Trip is open in Sorting, this test process (which has its own Photos access)
    /// deletes a marked photo and an unsorted one from the library, answering the iPadOS
    /// confirmation, with Piq in the background as when the person deletes them in Photos. Back
    /// in front, Piq drops both: the counter's total, the trash, the album count.
    func testPhotosDeletedOutsidePiqLeaveTheOpenSession() throws {
        try requireE2E()
        let library = try Oracle()
        let photos = library.tripPhotos
        let total = photos.count
        let app = launch()
        openTrip(app, count: total)
        // Keep the 1st photo, mark the 2nd; the 3rd is on screen.
        app.buttons[ID.keep].tap()
        expect(app, position: 2, total: total, marked: 0)
        app.buttons[ID.delete].tap()
        expect(app, position: 3, total: total, marked: 1)
        let onScreen = try currentPhoto(app)
        XCTAssertEqual(onScreen.filename, photos[2].filename)
        attachScreenshot("e2e-outside-delete-before")

        XCUIDevice.shared.press(.home)
        _ = app.wait(for: .runningBackgroundSuspended, timeout: 5)
        let gone = [photos[1].id, photos[5].id]
        let deletion = Self.change {
            PHAssetChangeRequest.deleteAssets(PHAsset.fetchAssets(withLocalIdentifiers: gone, options: nil))
        }
        try finish(deletion, answering: ["Delete"], "deleting \(photos[1].filename) and \(photos[5].filename)")
        XCTAssertEqual(PHAsset.fetchAssets(withLocalIdentifiers: gone, options: nil).count, 0, "both are gone from the library")

        app.activate()
        expect(app, position: 2, total: total - 2, marked: 0)
        XCTAssertEqual(try currentPhoto(app).filename, onScreen.filename, "the photo on screen stays")
        attachScreenshot("e2e-outside-deleted")
        app.buttons[ID.review].tap()
        XCTAssertTrue(app.descendants(matching: .any)[ID.emptyState].waitForExistence(timeout: 5), "the deleted photo left the trash")
        attachScreenshot("e2e-outside-deleted-review")
        app.buttons[ID.reviewBack].tap()
        expect(app, position: 2, total: total - 2, marked: 0)
        app.buttons[ID.back].tap()
        waitForLabel(app.buttons[ID.album(Self.trip)], "E2E Trip, \(total - 2) photos")
    }

    /// While E2E Trip is open in Sorting, this test process takes a marked photo and an unsorted
    /// one out of the album (album membership changes ask nothing). Piq's counter, trash and
    /// queue follow; adding them back queues them again.
    func testPhotosLeavingTheAlbumOutsidePiqLeaveTheOpenSession() async throws {
        try requireE2E()
        let library = try Oracle()
        let photos = library.tripPhotos
        let total = photos.count
        let app = launch()
        openTrip(app, count: total)
        wakeKeyboard(app)
        // Keep the 1st photo, mark the 2nd; the 3rd is on screen.
        press(.rightArrow, in: app)
        expect(app, position: 2, total: total, marked: 0)
        press(.leftArrow, in: app)
        expect(app, position: 3, total: total, marked: 1)
        let onScreen = try currentPhoto(app)
        XCTAssertEqual(onScreen.filename, photos[2].filename)

        let marked = photos[1], unsorted = photos[4]
        let albumID = library.trip.localIdentifier
        addTeardownBlock {
            try await Self.setMembership(of: [marked.id, unsorted.id], in: albumID, isMember: true)
        }

        // The marked photo leaves the album: out of the session and the trash.
        try await Self.setMembership(of: [marked.id], in: albumID, isMember: false)
        expect(app, position: 2, total: total - 1, marked: 0)
        XCTAssertEqual(try currentPhoto(app), PhotoOnScreen(position: "Photo 2 of \(total - 1)", filename: onScreen.filename, time: onScreen.time), "the photo on screen stays")
        attachScreenshot("e2e-outside-removed-marked")

        // A photo not sorted yet leaves too.
        try await Self.setMembership(of: [unsorted.id], in: albumID, isMember: false)
        expect(app, position: 2, total: total - 2, marked: 0)
        XCTAssertEqual(try currentPhoto(app).filename, onScreen.filename)
        attachScreenshot("e2e-outside-removed-unsorted")

        app.buttons[ID.review].tap()
        XCTAssertTrue(app.descendants(matching: .any)[ID.emptyState].waitForExistence(timeout: 5), "the marked photo left the trash")
        app.buttons[ID.reviewBack].tap()
        expect(app, position: 2, total: total - 2, marked: 0)

        // Back in the album: both are queued again in capture order. The photo on screen stays;
        // the marked one is older than it, so it is next.
        try await Self.setMembership(of: [marked.id, unsorted.id], in: albumID, isMember: true)
        expect(app, position: 2, total: total, marked: 0)
        XCTAssertEqual(try currentPhoto(app).filename, onScreen.filename, "the photo on screen stays")
        app.buttons[ID.next].tap()
        expect(app, position: 3, total: total, marked: 0)
        XCTAssertEqual(try currentPhoto(app).filename, marked.filename)
    }

    // MARK: First launch

    func testFirstLaunchAllowFullAccessShowsTheAlbums() throws {
        try requireE2E()
        let app = launchAfterResettingAccess()
        let prompt = try systemPrompt(containing: "Allow Full Access", "e2e-access-prompt")
        for title in ["Limit Access…", "Allow Full Access", "Don’t Allow"] {
            XCTAssertTrue(prompt.buttons[title].exists, "the prompt offers \(title)")
        }
        XCTAssertTrue(app.staticTexts["Waiting for access to Photos"].exists, "Piq waits quietly under the prompt")
        attachScreenshot("e2e-access-prompt")
        prompt.buttons["Allow Full Access"].tap()
        waitForAlbums(app)
        XCTAssertTrue(app.staticTexts["Connected to Photos"].exists)
        XCTAssertTrue(app.buttons[ID.album(Self.trip)].exists)
        attachScreenshot("e2e-access-full")
    }

    func testFirstLaunchDontAllowShowsWhyAndOpensSettings() throws {
        try requireE2E()
        let app = launchAfterResettingAccess()
        let prompt = try systemPrompt(containing: "Allow Full Access", "e2e-access-prompt-deny")
        prompt.buttons["Don’t Allow"].tap()
        XCTAssertTrue(app.staticTexts["Piq needs access to your photos"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Not connected"].exists)
        let openSettings = app.buttons[ID.openSettings]
        XCTAssertTrue(openSettings.exists)
        attachScreenshot("e2e-access-denied")
        openSettings.tap()
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 10), "Open Settings opens Settings")
        // Which page Settings lands on is up to Settings (on the iOS 26.5 simulator, a cold
        // launch stops at Apps rather than Piq's page); record it.
        _ = settings.navigationBars.firstMatch.waitForExistence(timeout: 10)
        Thread.sleep(forTimeInterval: 2)
        print("Settings opened at: \(settings.navigationBars.allElementsBoundByIndex.map(\.identifier))")
        attachScreenshot("e2e-access-settings")
        attachHierarchy("e2e-access-settings", settings)
        settings.terminate()
    }

    func testFirstLaunchLimitAccessShowsTheLimitedStateAndChangesTheSelection() throws {
        try requireE2E()
        let app = launchAfterResettingAccess()
        let prompt = try systemPrompt(containing: "Allow Full Access", "e2e-access-prompt-limit")
        prompt.buttons["Limit Access…"].tap()

        // iPadOS shows its photo picker to choose what Piq may see.
        let picked = try pickPhotos(3, named: "e2e-limited-picker", app: app)
        XCTAssertGreaterThan(picked, 0)

        let notice = app.staticTexts["Piq can only see the photos you've allowed."]
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "the limited-access notice")
        let recents = app.buttons[ID.album("Recents")]
        XCTAssertTrue(recents.waitForExistence(timeout: 10))
        waitForLabel(recents, "Recents, \(picked == 1 ? "1 photo" : "\(picked) photos")")
        XCTAssertTrue(app.buttons[ID.album("Favorites")].exists)
        let tiles = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'picker.album.'"))
        XCTAssertEqual(tiles.allElementsBoundByIndex.map(\.identifier), [ID.album("Recents"), ID.album("Favorites")], "Recents and Favorites only under limited access")
        attachScreenshot("e2e-limited")

        // Change selection presents the same picker, with the first photos already picked.
        app.buttons[ID.changeSelection].tap()
        let added = try pickPhotos(1, skipping: picked, named: "e2e-limited-change", app: app)
        XCTAssertEqual(added, 1)
        waitForLabel(recents, "Recents, \(picked + added) photos")
        attachScreenshot("e2e-limited-changed")

        // Launched again under limited access, iPadOS doesn't ask to pick more photos on its own
        // (Info.plist's PHPhotoLibraryPreventAutomaticLimitedAccessAlert); Piq's notice offers it.
        app.terminate()
        app.launch()
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        waitForLabel(recents, "Recents, \(picked + added) photos")
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(springboard.alerts.count, 0, "no automatic limited-access alert")
        XCTAssertFalse(app.images.matching(identifier: "PXGGridLayout-Info").firstMatch.exists, "no picker")
        attachScreenshot("e2e-limited-relaunched")
    }

    // MARK: Launching

    private func requireE2E() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PIQ_E2E"] == "1", "Needs a prepared simulator and TEST_RUNNER_PIQ_E2E=1 (see the class comment)")
        continueAfterFailure = false
    }

    @discardableResult
    private func launch(_ app: XCUIApplication = XCUIApplication()) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launchArguments = ["-PiqInMemoryStore"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        return app
    }

    /// Resets Piq's Photos permission, launches it (it asks at once) and grants full access
    /// again when the test ends.
    private func launchAfterResettingAccess() -> XCUIApplication {
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .photos)
        addTeardownBlock { @MainActor [springboard] in
            app.terminate()
            app.resetAuthorizationStatus(for: .photos)
            app.launchArguments = ["-PiqInMemoryStore"]
            app.launch()
            let allow = springboard.buttons["Allow Full Access"]
            if allow.waitForExistence(timeout: 15) {
                allow.tap()
            }
            XCTAssertTrue(app.buttons["picker.album.Recents"].waitForExistence(timeout: 15), "full access again")
            app.terminate()
        }
        return launch(app)
    }

    private func waitForAlbums(_ app: XCUIApplication) {
        let trip = app.buttons[ID.album(Self.trip)]
        if !trip.waitForExistence(timeout: 15) {
            attachHierarchy("app-no-albums", app)
            XCTFail("The picker doesn't list \(Self.trip): prepare the simulator (Tools/PhotoKitE2E/run-e2e.sh)")
        }
    }

    private func openTrip(_ app: XCUIApplication, count: Int) {
        waitForAlbums(app)
        app.buttons[ID.album(Self.trip)].tap()
        let start = app.buttons[ID.start]
        waitForLabel(start, "Start sorting · \(count) photos")
        start.tap()
        XCTAssertTrue(app.staticTexts[ID.counter].waitForExistence(timeout: 10), "the sorting screen")
    }

    // MARK: Sorting helpers

    private struct PhotoOnScreen: Equatable {
        let position: String
        let filename: String
        let time: String
    }

    private func photo(in app: XCUIApplication) -> XCUIElement {
        let photo = app.descendants(matching: .any)[ID.photo]
        XCTAssertTrue(photo.waitForExistence(timeout: 5), "the photo is on screen")
        return photo
    }

    /// The photo on screen, from its VoiceOver label ("Photo 3 of 25, E2E_1014.JPG, 08:23"), once
    /// its details are in. Checks that the time is the file's capture time.
    private func currentPhoto(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) throws -> PhotoOnScreen {
        let element = photo(in: app)
        let named = NSPredicate(format: "label CONTAINS 'E2E_'")
        _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: named, object: element)], timeout: 5)
        let parts = element.label.components(separatedBy: ", ")
        guard parts.count == 3 else {
            XCTFail("Unexpected photo label: \(element.label)", file: file, line: line)
            throw RecordedFailure()
        }
        let photo = PhotoOnScreen(position: parts[0], filename: parts[1], time: parts[2])
        let date = try XCTUnwrap(E2EMedia.captureDate(of: photo.filename), "an E2E photo: \(photo.filename)", file: file, line: line)
        XCTAssertEqual(photo.time, date.formatted(date: .omitted, time: .shortened), "\(photo.filename): the chip shows its capture time", file: file, line: line)
        return photo
    }

    /// Waits for the counter ("Photo 3 of 25") and the Review button ("Review, 2 marked").
    private func expect(_ app: XCUIApplication, position: Int, total: Int, marked: Int, file: StaticString = #filePath, line: UInt = #line) {
        let counter = app.staticTexts[ID.counter]
        let review = app.buttons[ID.review]
        let expectedCounter = "Photo \(position) of \(total)"
        let expectedReview = marked > 0 ? "Review, \(marked) marked" : "Review"
        let predicate = NSPredicate { _, _ in counter.label == expectedCounter && review.label == expectedReview }
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 8)
        XCTAssertEqual(result, .completed, "Expected “\(expectedCounter)” and “\(expectedReview)”, got “\(counter.label)” and “\(review.label)”", file: file, line: line)
    }

    /// Waits until the photo on screen is sharp, measured on a screenshot: each E2E photo has a
    /// patch of 2 px lines every 12 px, which reads as a strong pattern only at full resolution
    /// (a blurred preview or a placeholder is flat there). The card is found on the screenshot
    /// itself (`ScreenPixels.frontCard`): the photo element's accessibility frame has been seen
    /// spanning the card behind and the overflow of its aspect-filled image (735 x 912 pt, above
    /// the screen's top, for a 735 x 551 pt card with a portrait photo next).
    private func expectSharp(_ app: XCUIApplication, _ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let shown = try currentPhoto(app, file: file, line: line)
        let size = try XCTUnwrap(E2EMedia.pixelSize(of: shown.filename), shown.filename, file: file, line: line)
        let aspectRatio = CGFloat(size.width) / CGFloat(size.height)
        // A toast over the top of the card would hide its top edge.
        _ = app.descendants(matching: .any)[ID.toast].waitForNonExistence(timeout: 4)
        // The plain ground left of the grid, for comparison: flat whether sharp or not. Both are
        // measured on the same screenshot, until both hold (a card still sliding in fails them).
        var contrast = 0.0
        var flat = 0.0
        var card: CGRect?
        let deadline = Date().addingTimeInterval(8)
        repeat {
            Thread.sleep(forTimeInterval: 0.5)
            guard let screen = ScreenPixels(XCUIScreen.main.screenshot().image, screen: app.frame.size) else { continue }
            card = screen.frontCard(aspectRatio: aspectRatio)
            if let card {
                contrast = screen.contrast(in: Self.gridPatch, of: card)
                flat = screen.contrast(in: Self.flatPatch, of: card)
            }
        } while !(contrast >= 30 && flat < 10) && Date() < deadline
        print("Sharpness \(name): grid patch luminance spread \(Int(contrast)), plain patch \(Int(flat)), card \(card.map { "\($0.integral)" } ?? "not found")")
        attachScreenshot(name)
        XCTAssertNotNil(card, "\(name): the photo card is on the screenshot", file: file, line: line)
        XCTAssertGreaterThanOrEqual(contrast, 30, "\(name): the grid patch is sharp (luminance spread \(contrast))", file: file, line: line)
        XCTAssertLessThan(flat, 10, "\(name): the plain patch is flat (\(flat))", file: file, line: line)
    }

    /// The middle of the grid each E2E photo has at 55-93 % of its width and 68-92 % of its
    /// height (from the top), as fractions of the card. Photos fill their cards, so they hold
    /// for landscape and portrait alike.
    private static let gridPatch = CGRect(x: 0.62, y: 0.73, width: 0.24, height: 0.14)
    /// Plain ground left of the grid.
    private static let flatPatch = CGRect(x: 0.12, y: 0.73, width: 0.24, height: 0.14)

    private func wakeKeyboard(_ app: XCUIApplication) {
        Thread.sleep(forTimeInterval: 1.5)
        for _ in 0..<2 {
            app.windows.firstMatch.typeKey(XCUIKeyboardKey.shift.rawValue, modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    private func press(_ key: XCUIKeyboardKey, in app: XCUIApplication) {
        app.windows.firstMatch.typeKey(key, modifierFlags: [])
    }

    // MARK: Review helpers

    private func reviewTiles(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'review.tile.'"))
    }

    private func confirmEmptyTrash(_ app: XCUIApplication, count: Int) throws {
        let emptyTrash = app.buttons[ID.emptyTrash]
        XCTAssertTrue(emptyTrash.waitForExistence(timeout: 5))
        emptyTrash.tap()
        let confirm = app.buttons[ID.confirmDelete]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Piq's own confirmation")
        XCTAssertEqual(confirm.label, "Delete \(count) photos")
        XCTAssertTrue(app.staticTexts["Delete \(count) photos?"].exists)
        attachScreenshot("e2e-confirm-card")
        confirm.tap()
    }

    // MARK: System UI

    /// The alert iPadOS shows over Piq that has a button titled `buttonTitle`, wherever XCUITest
    /// finds it: SpringBoard's alerts, or Piq's own. Fails the test when none comes up.
    private func systemPrompt(containing buttonTitle: String, _ name: String) throws -> XCUIElement {
        let app = XCUIApplication()
        let candidates = [springboard.alerts.firstMatch, app.alerts.firstMatch, springboard.sheets.firstMatch]
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            for candidate in candidates where candidate.exists && candidate.buttons[buttonTitle].exists {
                return candidate
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        attachHierarchy("\(name)-springboard", springboard)
        attachHierarchy("\(name)-app", app)
        attachScreenshot("\(name)-missing")
        XCTFail("No system prompt with “\(buttonTitle)” came up within 20 s")
        throw RecordedFailure()
    }

    private func button(in element: XCUIElement, oneOf titles: [String]) throws -> XCUIElement {
        for title in titles where element.buttons[title].exists {
            return element.buttons[title]
        }
        attachHierarchy("prompt-buttons", springboard)
        XCTFail("None of \(titles) in \(element.label)")
        throw RecordedFailure()
    }

    /// Picks `count` photos in the system's limited-library picker (bridged into Piq's own
    /// hierarchy: a popover whose photos are images labelled "Photo, 11 October, 19:07", newest
    /// first), starting `skipping` photos in, and taps Done. Returns how many it picked.
    private func pickPhotos(_ count: Int, skipping skipped: Int = 0, named name: String, app: XCUIApplication) throws -> Int {
        let photos = app.images.matching(NSPredicate(format: "identifier == 'PXGGridLayout-Info' AND label BEGINSWITH 'Photo'"))
        guard photos.firstMatch.waitForExistence(timeout: 20) else {
            attachScreenshot(name)
            attachHierarchy("\(name)-app", app)
            attachHierarchy("\(name)-springboard", springboard)
            XCTFail("The system photo picker didn't come up")
            throw RecordedFailure()
        }
        Thread.sleep(forTimeInterval: 1)
        attachScreenshot(name)
        let available = photos.count
        guard available > skipped else {
            XCTFail("The picker shows \(available) photos; \(skipped) are already picked")
            throw RecordedFailure()
        }
        // Remote-view elements report isHittable == false, so tap where they are, keeping to
        // cells wholly inside the popover (above Done's toolbar row and the window's bottom).
        let window = app.windows.firstMatch.frame
        var picked = 0
        for index in skipped..<available where picked < count {
            let photo = photos.element(boundBy: index)
            let frame = photo.frame
            guard frame.width > 20, window.insetBy(dx: 0, dy: 120).contains(frame) else { continue }
            photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            picked += 1
            Thread.sleep(forTimeInterval: 0.3)
        }
        attachScreenshot("\(name)-picked")
        let done = app.buttons["Update"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "the picker's Done button")
        XCTAssertEqual(done.label, "Done")
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 10), "the picker closes")
        return picked
    }

    /// Taps whichever of `titles` SpringBoard shows (a prompt's button), every time one shows,
    /// until `isDone` holds or `timeout` passes. Returns whether `isDone` held.
    private func answerPrompts(tapping titles: [String], until isDone: () -> Bool, timeout: TimeInterval) -> Bool {
        let button = springboard.buttons.matching(NSPredicate(format: "label IN %@", titles)).firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while !isDone() {
            guard Date() < deadline else { return false }
            if button.exists {
                print("Answering a prompt with \(button.label)")
                button.tap()
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return true
    }

    /// Waits for `change` to finish, answering its confirmation with whichever of `titles` shows,
    /// and fails the test if it doesn't finish within 90 s or PhotoKit reports an error.
    private func finish(_ change: PhotoKitAnswer<ChangeOutcome>, answering titles: [String], _ what: String) throws {
        let started = Date()
        guard answerPrompts(tapping: titles, until: { change.value != nil }, timeout: 90) else {
            attachHierarchy("\(what)-springboard", springboard)
            attachScreenshot("\(what)-no-answer")
            XCTFail("\(what): not done 90 s later (no confirmation with \(titles) was answered)")
            throw RecordedFailure()
        }
        print("\(what): done in \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
        if case .failed(let message) = change.value {
            XCTFail("\(what): \(message)")
            throw RecordedFailure()
        }
    }

    // MARK: Attachments

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attachHierarchy(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Waits until `element`'s label reads `label`, the way Piq writes it on screen or the way
    /// VoiceOver reads it ("Start sorting · 25 photos" or "Start sorting, 25 photos").
    private func waitForLabel(_ element: XCUIElement, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let expected = Self.spoken(label)
        let predicate = NSPredicate { _, _ in Self.spoken(element.label) == expected }
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 10)
        XCTAssertEqual(result, .completed, "Expected “\(label)”, got “\(element.label)”", file: file, line: line)
    }

    /// Waits until `element`'s label mentions `text`.
    private func waitForLabel(_ element: XCUIElement, containing text: String, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 10)
        XCTAssertEqual(result, .completed, "Expected a label with “\(text)”, got “\(element.label)”", file: file, line: line)
    }

    /// A line of copy as VoiceOver reads it: the "·" between its parts becomes a pause.
    private nonisolated static func spoken(_ text: String) -> String {
        text.replacingOccurrences(of: " · ", with: ", ")
    }

    // MARK: Photos, from this test process

    /// Every E2E photo's identifier, filename and hidden state.
    private static func e2ePhotosHiddenState() -> [(String, String, Bool)] {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        var photos: [(String, String, Bool)] = []
        PHAsset.fetchAssets(with: .image, options: options).enumerateObjects { asset, _, _ in
            let name = PHAssetResource.assetResources(for: asset).first { $0.type == .photo }?.originalFilename ?? ""
            if name.hasPrefix("E2E_") { photos.append((asset.localIdentifier, name, asset.isHidden)) }
        }
        return photos
    }

    /// Starts a change to the library at once, from this process; poll it with `finish`.
    private static func change(_ block: @escaping @Sendable () -> Void) -> PhotoKitAnswer<ChangeOutcome> {
        let answer = PhotoKitAnswer<ChangeOutcome>()
        PHPhotoLibrary.shared().performChanges(block) { @Sendable _, error in
            answer.resolve(error.map { .failed($0.localizedDescription) } ?? .done)
        }
        return answer
    }

    /// Takes photos out of an album or puts them back. Album membership changes ask nothing, so
    /// this simply waits for PhotoKit.
    private static func setMembership(of assetIDs: [String], in albumID: String, isMember: Bool) async throws {
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject,
                  let request = PHAssetCollectionChangeRequest(for: album) else { return }
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
            if isMember {
                request.addAssets(assets)
            } else {
                request.removeAssets(assets)
            }
        }
    }
}

/// Ends a test after `XCTFail` has said why.
private struct RecordedFailure: Error {}

/// How a change this process asked PhotoKit for ended.
private enum ChangeOutcome: Sendable {
    case done
    case failed(String)
}

/// The answer to a PhotoKit request made with a completion handler, which PhotoKit calls on a
/// queue of its own; the test reads it while it polls the UI.
private final class PhotoKitAnswer<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var answer: Value?

    var value: Value? { lock.withLock { answer } }

    func resolve(_ value: Value) {
        lock.withLock { answer = value }
    }
}

/// A screenshot as luminance (0...255), upright, addressed in points from the top left.
@MainActor
private struct ScreenPixels {
    /// Brighter than this is photo; Piq's ground (#0E0E0D) reads 14, the card's shadow less.
    static let groundThreshold = 40

    let width: Int
    let height: Int
    /// Pixels per point.
    let scale: CGFloat
    let size: CGSize
    let pixels: [UInt8]

    init?(_ screenshot: UIImage, screen: CGSize) {
        guard var cgImage = screenshot.cgImage, screen.width > 0 else { return nil }
        if (cgImage.width > cgImage.height) != (screen.width > screen.height) {
            // Not stored the way it is shown: draw it upright, at full resolution.
            let format = UIGraphicsImageRendererFormat()
            format.scale = screenshot.scale
            let upright = UIGraphicsImageRenderer(size: screen, format: format).image { _ in screenshot.draw(in: CGRect(origin: .zero, size: screen)) }
            guard let drawn = upright.cgImage else { return nil }
            cgImage = drawn
        }
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        self.scale = CGFloat(width) / screen.width
        self.size = screen
        self.pixels = pixels
    }

    func luminance(x: CGFloat, y: CGFloat) -> Int {
        let column = min(max(Int(x * scale), 0), width - 1)
        let row = min(max(Int(y * scale), 0), height - 1)
        return Int(pixels[row * width + column])
    }

    /// The photo card in front, whose shape is `aspectRatio`. It is centered across the stage:
    /// down the middle, below the 76 pt top bar, its top is where a long bright run starts (a
    /// hairline or a toast's text is short); its sides are where the row 60 pt lower (past the
    /// filename chip, above the photo's own lettering) meets the dark ground.
    func frontCard(aspectRatio: CGFloat) -> CGRect? {
        let middle = size.width / 2
        var top: CGFloat?
        var runStart: CGFloat?
        var y: CGFloat = 80
        while y < size.height - 80 {
            if luminance(x: middle, y: y) > Self.groundThreshold {
                let start = runStart ?? y
                runStart = start
                if y - start >= 60 {
                    top = start
                    break
                }
            } else {
                runStart = nil
            }
            y += 1
        }
        guard let top else { return nil }
        let row = top + 60
        var left = middle, right = middle
        while left > 0, luminance(x: left - 0.5, y: row) > Self.groundThreshold { left -= 0.5 }
        while right < size.width, luminance(x: right + 0.5, y: row) > Self.groundThreshold { right += 0.5 }
        let card = CGRect(x: left, y: top, width: right - left, height: (right - left) / aspectRatio)
        guard card.width >= 100, card.maxY <= size.height else { return nil }
        return card
    }

    /// Standard deviation of luminance in `patch` (fractions of `card`).
    func contrast(in patch: CGRect, of card: CGRect) -> Double {
        let x0 = max(Int((card.minX + card.width * patch.minX) * scale), 0)
        let y0 = max(Int((card.minY + card.height * patch.minY) * scale), 0)
        let x1 = min(Int((card.minX + card.width * patch.maxX) * scale), width)
        let y1 = min(Int((card.minY + card.height * patch.maxY) * scale), height)
        guard x1 - x0 > 4, y1 - y0 > 4 else { return 0 }
        var sum = 0.0, sumOfSquares = 0.0
        for row in y0..<y1 {
            for column in x0..<x1 {
                let value = Double(pixels[row * width + column])
                sum += value
                sumOfSquares += value * value
            }
        }
        let count = Double((x1 - x0) * (y1 - y0))
        let mean = sum / count
        return max(sumOfSquares / count - mean * mean, 0).squareRoot()
    }
}

/// The library as PhotoKit shows it to this test process (which has its own full access, from
/// `test00GrantFullAccess`): what Piq should show, independently of Piq.
@MainActor
private struct Oracle {
    struct Photo {
        let id: String
        let filename: String
    }

    let trip: PHAssetCollection
    /// E2E Trip's photos, oldest first.
    let tripPhotos: [Photo]

    init() throws {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            XCTFail("The test runner needs full Photos access: run test00GrantFullAccess first")
            throw RecordedFailure()
        }
        var found: PHAssetCollection?
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil).enumerateObjects { album, _, stop in
            if album.localizedTitle == "E2E Trip" {
                found = album
                stop.pointee = true
            }
        }
        guard let trip = found else {
            XCTFail("No E2E Trip album: prepare the simulator (Tools/PhotoKitE2E/run-e2e.sh)")
            throw RecordedFailure()
        }
        self.trip = trip
        tripPhotos = Self.photos(in: trip).map { asset in
            Photo(id: asset.localIdentifier, filename: PHAssetResource.assetResources(for: asset).first { $0.type == .photo }?.originalFilename ?? "")
        }
    }

    func photos(in subtype: PHAssetCollectionSubtype) -> [PHAsset] {
        guard let album = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil).firstObject else { return [] }
        return Self.photos(in: album)
    }

    /// Photos from the person's library (no videos), oldest first.
    private static func photos(in album: PHAssetCollection) -> [PHAsset] {
        var photos: [PHAsset] = []
        PHAsset.fetchAssets(in: album, options: nil).enumerateObjects { asset, _, _ in
            if asset.mediaType == .image, asset.sourceType == .typeUserLibrary { photos.append(asset) }
        }
        return photos.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
    }
}

/// What `Tools/PhotoKitE2E/gen_media.swift` wrote into the E2E photos, by filename (its formulas).
private enum E2EMedia {
    static func pixelSize(of filename: String) -> (width: Int, height: Int)? {
        guard filename.hasPrefix("E2E_"), let number = Int(filename.dropFirst(4).prefix(4)), (1001...1060).contains(number) else { return nil }
        let index = number - 1001
        if index == 9 { return (8064, 6048) }
        let (long, short) = index % 5 == 2 ? (3600, 2400) : (4032, 3024)
        return index % 3 == 1 ? (short, long) : (long, short)
    }

    /// Capture date (local time).
    static func captureDate(of filename: String) -> Date? {
        guard filename.hasPrefix("E2E_"), let number = Int(filename.dropFirst(4).prefix(4)), (1001...1060).contains(number) else { return nil }
        let slot = ((number - 1001) * 37) % 60
        let minutes = 8 * 60 + (slot % 30) * 23
        let components = DateComponents(year: 2026, month: 10, day: slot < 30 ? 10 : 11, hour: minutes / 60, minute: minutes % 60, second: (slot * 13) % 60)
        return Calendar.current.date(from: components)
    }
}
