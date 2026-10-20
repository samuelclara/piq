import OSLog
import SwiftData
import SwiftUI

@main
struct PiqApp: App {
    @State private var app: AppModel

    init() {
        _app = State(initialValue: AppEnvironment.makeAppModel())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
        }
    }
}

/// Builds the app's dependencies: PhotoKit and an on-disk SwiftData store, or (DEBUG) the mock
/// library for UI tests, screenshots and trying Piq without a photo library.
@MainActor
enum AppEnvironment {
    static func makeAppModel() -> AppModel {
        #if DEBUG
        if let options = MockLaunchOptions.current {
            return options.makeAppModel()
        }
        // `-PiqInMemoryStore`: real PhotoKit with a fresh session store, so end-to-end UI tests
        // don't resume an earlier run's sessions.
        if ProcessInfo.processInfo.arguments.contains("-PiqInMemoryStore") {
            return AppModel(library: PhotoKitLibraryClient(), images: PhotoKitImageSource(), container: PreviewSupport.inMemoryContainer())
        }
        #endif
        return AppModel(library: PhotoKitLibraryClient(), images: PhotoKitImageSource(), container: makeContainer())
    }

    private static func makeContainer() -> ModelContainer {
        do {
            return try SessionStore.makeContainer()
        } catch {
            // Keep working with an in-memory store; sessions just won't survive this launch.
            Logger.persistence.error("Opening the session store failed: \(error.localizedDescription, privacy: .public)")
            do {
                return try SessionStore.makeContainer(ModelConfiguration(isStoredInMemoryOnly: true))
            } catch {
                fatalError("Couldn't create an in-memory SwiftData store: \(error)")
            }
        }
    }
}

extension Logger {
    static let photos = Logger(subsystem: "io.belleville.piq", category: "photos")
    static let persistence = Logger(subsystem: "io.belleville.piq", category: "persistence")
}

#if DEBUG
/// Launch arguments for running against the mock library (DEBUG builds only):
///
///     -PiqMockLibrary                    use the mock library and an in-memory store
///     -PiqMockAccess limited             notDetermined | authorized | limited | denied | restricted
///     -PiqMockScenario sorting           albums | resume | sorting | review | reviewPartial | emptyTrash
///     -PiqMockLatency 0.8                seconds each sharp image takes to "download"
///     -PiqMockDeletion cancel            succeed | cancel | fail
///     -PiqMockDeletionDelay 30           seconds the "system prompt" takes to answer (0.35)
///     -PiqMockPersistentStore            keep sessions on disk across launches, in their own store
///                                        (PiqMock.store, apart from the real one); the mock library
///                                        then remembers its deleted photos too
///     -PiqMockResetStore                 with -PiqMockPersistentStore: start that store over
///
/// A scenario seeds its session only into a store that doesn't have it yet. Mock launches also
/// listen for `MockRemoteControl` commands, so UI tests can change the library while Piq runs.
/// Unit-test runs use the mock library too, so the test host never prompts for Photos access.
struct MockLaunchOptions {
    var scenario: PreviewSupport.Scenario?
    var access: LibraryAccess
    var latency: Duration
    var deletion: MockPhotoLibrary.DeletionBehavior
    var deletionDelay: Duration
    var persistentStore: Bool
    var resetsStore: Bool

    static var current: MockLaunchOptions? {
        let process = ProcessInfo.processInfo
        let isUnitTestHost = process.environment["XCTestConfigurationFilePath"] != nil
        guard process.arguments.contains("-PiqMockLibrary") || isUnitTestHost else { return nil }
        let defaults = UserDefaults.standard
        let deletionDelay = defaults.object(forKey: "PiqMockDeletionDelay") == nil
            ? MockPhotoLibrary.defaultDeletionDelay
            : .milliseconds(Int(defaults.double(forKey: "PiqMockDeletionDelay") * 1000))
        return MockLaunchOptions(
            scenario: defaults.string(forKey: "PiqMockScenario").flatMap(PreviewSupport.Scenario.init(rawValue:)),
            access: defaults.string(forKey: "PiqMockAccess").flatMap(LibraryAccess.init(rawValue:)) ?? .authorized,
            latency: .milliseconds(Int(defaults.double(forKey: "PiqMockLatency") * 1000)),
            deletion: defaults.string(forKey: "PiqMockDeletion").flatMap(MockPhotoLibrary.DeletionBehavior.init(rawValue:)) ?? .succeed,
            deletionDelay: deletionDelay,
            // Flags without a value: UserDefaults skips them, so read the arguments.
            persistentStore: process.arguments.contains("-PiqMockPersistentStore") && !isUnitTestHost,
            resetsStore: process.arguments.contains("-PiqMockResetStore")
        )
    }

    /// The app model these options describe. A mock launch also listens for `MockRemoteControl`
    /// commands.
    @MainActor
    func makeAppModel() -> AppModel {
        let app = PreviewSupport.appModel(
            scenario,
            access: access,
            fullImageLatency: latency,
            deletion: deletion,
            deletionDelay: deletionDelay,
            persistence: persistentStore ? .onDisk(reset: resetsStore) : .inMemory
        )
        if ProcessInfo.processInfo.arguments.contains("-PiqMockLibrary") {
            MockRemoteControl.listen(to: app)
        }
        return app
    }
}
#endif
