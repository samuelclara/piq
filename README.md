# piq

Piq makes it fast to sort photos right after you import them into Apple Photos. Pick an album,
swipe through each photo full screen (left marks it for deletion, right keeps it), review what
you marked, then empty Piq's trash in one go. Nothing leaves Photos until you empty the trash and
confirm, and even then the photos go to Recently Deleted for 30 days.

Native SwiftUI for iPadOS 17 and later, no third-party dependencies.

## Requirements

- Xcode 16 or later (built and tested with Xcode 26.6 and the iPadOS 26.5 SDK). The project uses
  Xcode's synchronized folders, so files you add under `Piq/` are picked up automatically.
- An iPad running iPadOS 17 or later, or an iPad simulator.

## Run in the simulator

Open `Piq.xcodeproj`, pick an iPad simulator, and press Run. Or from the command line:

```sh
xcodebuild -project Piq.xcodeproj -scheme Piq \
  -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' build
```

The simulator's photo library starts almost empty. Drag images onto the simulator window, or:

```sh
xcrun simctl addmedia booted ~/Pictures/some-folder/*.jpg
```

### Trying it without photos

Debug builds can run against a built-in mock library (a 400-photo "Iceland 2026" album and a
few smaller ones, using the images in `Piq/Preview Content`). In Xcode, open
*Product › Scheme › Edit Scheme… › Run › Arguments* and tick `-PiqMockLibrary`. More options:

| Argument | Values | Effect |
| --- | --- | --- |
| `-PiqMockLibrary` | | Use the mock library and an in-memory store |
| `-PiqMockAccess` | `notDetermined` `authorized` `limited` `denied` `restricted` | Simulate a Photos authorization outcome |
| `-PiqMockScenario` | `albums` `resume` `sorting` `review` `reviewPartial` `emptyTrash` | Open straight into a state |
| `-PiqMockLatency` | seconds, e.g. `0.8` | Make sharp images "download" slowly, to see the blurry preview and spinner |
| `-PiqMockDeletion` | `succeed` `cancel` `fail` | How the "Delete" system prompt resolves |
| `-PiqMockDeletionDelay` | seconds, e.g. `30` | How long the stand-in "Delete" prompt stays up (default 0.35) |
| `-PiqMockPersistentStore` | | Keep sessions on disk across launches, in their own store (`PiqMock.store`, apart from the real one) |
| `-PiqMockResetStore` | | With `-PiqMockPersistentStore`: start that store over |

`-PiqInMemoryStore` (also Debug only) runs against the real photo library with a fresh,
in-memory session store, so end-to-end tests don't resume an earlier run's sessions.

## Run on your iPad

1. **Turn on Developer Mode** on the iPad (*Settings › Privacy & Security › Developer Mode*),
   then connect it to your Mac with a cable (or pair it over Wi‑Fi in Xcode's *Devices and
   Simulators* window).
2. **Set your signing team.** Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig`
   and put your team ID in it (Xcode › Settings › Accounts shows it, or developer.apple.com ›
   Membership). Git ignores that file, so your team ID stays out of the repo; every target reads
   it through `Config/Signing.xcconfig`. A free Apple ID ("Personal Team") works. Leave
   *Automatically manage signing* on. (Picking a team in *Signing & Capabilities* also works, but
   Xcode then writes it into the project file.)
3. **Make the bundle identifier yours.** `io.belleville.piq` must be unique to your team; if
   Xcode reports it's unavailable, change it (for example to `com.yourname.piq`).
4. Choose your iPad as the run destination and press Run. With a free Apple ID, the first launch
   needs you to trust your developer certificate on the iPad (*Settings › General › VPN & Device
   Management*).

From the command line, once `Config/Local.xcconfig` is set (or by passing the team):

```sh
xcodebuild -project Piq.xcodeproj -scheme Piq \
  -destination 'platform=iOS,name=<your iPad name>' \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=<your team ID> build
```

### Photos permission

Piq asks for full read/write access on first launch. The relevant keys live in `Piq/Info.plist`:

| Key | Why |
| --- | --- |
| `NSPhotoLibraryUsageDescription` | The text iPadOS shows when Piq asks for access. Read/write access needs only this key (`NSPhotoLibraryAddUsageDescription` is for apps that only add photos, so Piq doesn't use it). |
| `PHPhotoLibraryPreventAutomaticLimitedAccessAlert` | Stops iPadOS from re-prompting on every launch when you've given limited access; Piq has its own *Change selection* button instead. |

If you deny access, Piq explains why it needs it and offers a button to open Settings. With
limited access, Piq lists Recents and Favorites, holding the photos you've allowed. (iPadOS still
lists your albums in that mode, but with only the allowed photos in them, so Piq leaves them out
rather than sort a partial album.) Photos you sorted earlier that fall outside the selection
stay in their session and in the trash; Piq can't delete them until it can see them again.
If you take access away while sorting, Piq goes back to the albums and keeps every session for
when access returns.

## How it works

```
Piq/
  App/            app entry, AppModel (access, albums, sessions, navigation), RootView
  Model/          SwipeAction, SortingState (the session engine), SortingSession (SwiftData)
  Services/       PhotoKit client and image source, PhotoWindowLoader, session store/controller,
                  Mock/ (mock library and preview scenarios, Debug only)
  DesignSystem/   palette, type scale, metrics, buttons and shared components
  Features/       AlbumPicker/, Sorting/, Review/
  Resources/      fonts (with their licenses) and the asset catalog
  Preview Content/ mock photos for previews and the mock library
Tools/            scripts that prepare simulators for the gated real-library tests
```

- **Sessions.** Each album has one `SortingSession` in SwiftData: the album's identifier, its
  photos' identifiers (oldest first), a cursor (the photo on screen), a decision per photo
  (Delete, Keep, or unsorted), the marked photos and an undo log of decisions in the order they
  were made (a decision that replaced another remembers it). Moving with Previous and Next saves
  only the cursor and isn't undoable. Every decision is saved the moment it lands, so you can quit (or be killed) at any point and
  resume. The photo list lives in a record of its own (`SessionPhotos`), so a decision only
  writes the small session row: under a millisecond per swipe even for a 50,000-photo Recents.
  On launch the picker selects the album you sorted last.
- **Library changes.** Piq watches the library (`PHPhotoLibraryChangeObserver`, debounced
  300 ms, and only for changes that add, remove or reorder photos or rename albums). Photos
  deleted elsewhere drop out of sessions and the trash; photos added to an album since you
  started are queued unsorted in album order after the photo on screen (which stays), so
  resuming also sorts what's new. If the album
  itself is deleted while you're in it, Piq says so and goes back to the albums.
- **Images.** The sorting screen keeps exactly the current photo and the next three loaded
  (`PHCachingImageManager`, high-quality format, iCloud downloads allowed), plus the last photo
  decided so Undo brings it back sharp, and releases the rest. A photo shows a blurred preview
  first (the thumbnail Photos stores, or a quick 512 px image) while the sharp one loads; with a
  spinner only if an iCloud download keeps it waiting. "Full resolution" here means the screen's
  native resolution (about 2400–2750 px on the long edge): as sharp as the display can show,
  without decoding 24–48 MP originals (100–190 MB each) for every prefetched photo. The size is
  set in one place, `PhotoKitImageSource.fullImageSize`. Requests for photos that leave the
  window are cancelled, and Review's grid lets go of thumbnails scrolled off screen, so memory
  stays flat with hundreds of photos.
- **Deleting.** Swiping left only adds a photo to Piq's own trash. *Empty trash* calls
  `PHAssetChangeRequest.deleteAssets` inside `performChanges`; iPadOS then asks you to confirm.
  If you decline, the trash stays as it was. Photos that can't be deleted (for example ones
  synced from a computer) are left out of Piq altogether, as are shared-album photos.
- **New swipe actions.** Everything about an action (direction, title, icon, color, key,
  VoiceOver name) comes from the `SwipeAction` enum, so turning the right swipe into "edit" later
  means adding a case there and handling it in `SortingState.apply(_:)`.

## Tests and screenshots

The default suites run against the mock library and need nothing but a booted iPad simulator:

```sh
DEST='platform=iOS Simulator,name=iPad Pro 11-inch (M5)'

# Unit tests: session engine, persistence and migration, app model, races, library and access
# changes, image loading policy, layouts (332 tests; 39 are gated or opt-in and skip by default)
xcodebuild test -project Piq.xcodeproj -scheme Piq -destination "$DEST" -only-testing:PiqTests

# UI tests on the mock library: every screen and state, quit and resume, keyboard,
# accessibility audits, narrow windows (100 tests; 15 gated)
xcodebuild test -project Piq.xcodeproj -scheme Piq -destination "$DEST" -only-testing:PiqUITests

# Screenshots of every screen and state, in landscape and portrait
xcodebuild test -project Piq.xcodeproj -scheme Piq -destination "$DEST" \
  -only-testing:PiqUITests/ScreenshotTour -resultBundlePath Tour.xcresult
xcrun xcresulttool export attachments --path Tour.xcresult --output-path Screenshots
```

Some tests are skipped unless you turn them on (the `TEST_RUNNER_` prefix passes the variable to
the tests):

| Variable | Tests | Needs |
| --- | --- | --- |
| `TEST_RUNNER_PIQ_E2E=1` | `PhotoKitIntegrationTests`, `PhotoKitEndToEndTests`, `PickerRealLibraryTests` | A simulator prepared by `Tools/PhotoKitE2E/run-e2e.sh`, which does everything (media, import, granting access through the real prompt, albums) and runs them: `SIM=<udid> DD=<scratch dir> Tools/PhotoKitE2E/run-e2e.sh all` |
| `TEST_RUNNER_PIQ_E2E=1` | `PerformanceRealLibraryTests`, `PerformanceSortingTests` | A simulator with 400+ full-size photos: `Tools/Performance/prepare-library.sh <udid> . <scratch dir> all`, and `… reset` before each run. Run `PerformanceSortingTests` first on a fresh simulator (it answers the Photos prompt). |
| `TEST_RUNNER_PIQ_SNAPSHOTS=1` | `ReviewLayoutSnapshotTests`, `ExperiencePreviewSnapshots` | Nothing; they attach renderings of each state to look at |
| `TEST_RUNNER_PIQ_A11Y_SETTINGS=1` | `ExperienceAccessibilitySettingsTests` | Nothing; turns Bold Text, Increase Contrast and Reduce Motion on in Settings, then off again |

Use simulators you don't mind changing for the gated runs: they import photos, delete some (to
Recently Deleted) and reset Piq's Photos permission. On iOS 26 simulators,
`xcrun simctl privacy grant photos` doesn't satisfy PhotoKit, which is why the tests answer the
real prompt.

Every screen also has SwiftUI previews that render from the mock photos in
`Piq/Preview Content`, so they work without a photo library.

## Decisions worth knowing

- **Full resolution** is the display's native resolution, not the original's (see *Images*).
- **Left out of Piq:** videos, shared-album photos and photos synced from a computer (Piq can't
  delete those), and hidden photos (iPadOS doesn't give them to apps).
- **Recents and Favorites** take the titles Photos gives them; Piq's own copy is English only.
- **A finished album with photos still in the trash** shows *Review · 50 photos marked* on the
  picker and opens Review, so nothing marked is forgotten.
- **The confirmation before emptying the trash** is Piq's own card, followed by the system's
  prompt; declining either leaves the trash as it was.
- **Restore** reads *Restore* with nothing selected and *Restore 3* with a selection.
- **Times on the chip** follow the device's locale (14:32, or 2:32 PM).
- **Text size** grows with Dynamic Type up to the xxLarge size; the layouts are checked there,
  in portrait, landscape and narrow Split View windows.
- **Previous and Next** move between photos without deciding. A photo you skip stays unsorted:
  past the last photo Piq says how many are left, and Resume starts at the first unsorted one.
  Going back to a decided photo shows its decision; Delete or Keep replaces it.
- **"Connected to Photos"** on the picker opens the Photos app.
- **Cancel session:** an album with a session shows *Cancel session* beside *Resume* on the
  picker. After a confirmation, Piq forgets the album's decisions, its place and its trash list
  (Photos is left as it is), and the album offers *Start sorting* again. It can't be undone.
- **Zoom:** pinch a photo (sorting screen or Review's preview) to zoom up to 5×, or double-tap
  to zoom in to 2.5× and back out. Zoomed in, one finger moves the photo instead of swiping it
  (or, in the preview, instead of closing it); Delete, Keep and the arrow keys still decide. Past
  1.2× the photo is shown from the original's pixels, up to 24 MP (96 MB), held only while it is
  zoomed.
- **Keyboard:** ← and → decide (holding a key decides once), ⌘[ and ⌘] go to the previous and
  next photo without deciding, ⌘Z undoes, Return starts sorting
  on the picker, ⌘F searches the albums (Return in the search field only ends the search;
  Escape or ⌘. clears it), ⌘A selects all in Review, and Escape (or ⌘.) closes the
  confirmation and the preview.
- **"Date created"** on the picker lists the album made last first. PhotoKit has no public
  creation date for albums; it does list regular albums in the order they were made when asked
  for no particular order. Apple doesn't document that, so `PickerRealLibraryTests` checks it
  (titles, photos, renames and folder order don't change it). Recents and Favorites stay first
  in every order. Not checked: albums that arrive through iCloud Photos (the simulator has none)
  probably count from when they reached the device.

## Fonts

Bricolage Grotesque (SemiBold and Bold, in its default and 36 pt optical cuts) and Hanken
Grotesk (Regular to Bold) are bundled under the SIL Open Font License 1.1; the license texts are
in `Piq/Resources/Fonts`.
