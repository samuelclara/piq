#if DEBUG
import Foundation

/// Lets UI tests change the mock library while Piq runs, the way someone would in Settings or in
/// Photos, and kill Piq at the worst moment: the test posts the Darwin notification
/// `MockRemoteControl.prefix` + a command's raw value. Mock launches (`-PiqMockLibrary`) listen;
/// nothing else does.
@MainActor
enum MockRemoteControl {
    static let prefix = "io.belleville.piq.mock."

    enum Command: String, CaseIterable {
        /// Photos access changes, as in Settings. Piq notices when it becomes active again.
        case accessAuthorized = "access.authorized"
        case accessLimited = "access.limited"
        case accessDenied = "access.denied"
        /// The photo on screen in the open session is deleted in Photos.
        case deleteCurrentPhoto = "photo.deleteCurrent"
        /// The first photo in the open session's trash is deleted in Photos.
        case deleteFirstMarkedPhoto = "photo.deleteFirstMarked"
        /// Three new photos are added to the open session's album.
        case addPhotos = "photos.add"
        /// The open session's album is deleted in Photos (its photos stay in the library).
        case deleteAlbum = "album.delete"
        /// Piq is killed on the spot, as by a crash or the system reclaiming its memory: nothing
        /// runs on the way out. (XCUITest's `terminate()` takes about a second to land.)
        case kill = "app.kill"
        /// Piq is killed the moment the next decision lands in the open session, before anything
        /// else runs: the harshest time to lose it. A UI test can't time that itself, since a tap
        /// returns only once the app has settled.
        case killOnNextDecision = "app.killOnNextDecision"
    }

    private static weak var app: AppModel?

    /// Starts listening for commands to the mock library of `app`.
    static func listen(to app: AppModel) {
        let isListening = self.app != nil
        self.app = app
        guard !isListening else { return }
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for command in Command.allCases {
            CFNotificationCenterAddObserver(center, nil, { _, _, name, _, _ in
                guard let name = name?.rawValue as String? else { return }
                Task { @MainActor in MockRemoteControl.handle(name) }
            }, (prefix + command.rawValue) as CFString, nil, .deliverImmediately)
        }
    }

    private static func handle(_ name: String) {
        guard name.hasPrefix(prefix),
              let command = Command(rawValue: String(name.dropFirst(prefix.count))),
              let app, let library = app.library as? MockPhotoLibrary else { return }
        let session = app.activeSession
        switch command {
        case .accessAuthorized:
            library.access = .authorized
        case .accessLimited:
            library.access = .limited
        case .accessDenied:
            library.access = .denied
        case .deleteCurrentPhoto:
            if let id = session?.state.currentAssetID {
                library.remove([id])
            }
        case .deleteFirstMarkedPhoto:
            if let id = session?.state.markedInOrder.first {
                library.remove([id])
            }
        case .addPhotos:
            if let session {
                library.addPhotos(3, toAlbum: session.albumID)
            }
        case .deleteAlbum:
            if let session {
                library.removeAlbum(session.albumID)
            }
        case .kill:
            Darwin.kill(getpid(), SIGKILL)
        case .killOnNextDecision:
            guard let session else { return }
            let sorted = session.state.sortedCount
            let deadline = ContinuousClock.now + .seconds(30)
            Task { @MainActor in
                while session.state.sortedCount == sorted, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(2))
                }
                if session.state.sortedCount != sorted {
                    Darwin.kill(getpid(), SIGKILL)
                }
            }
        }
    }
}
#endif
