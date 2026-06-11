import SwiftUI
import Sentry
import Sparkle

@main
struct CoachCapApp: App {
    @StateObject private var appState = AppState()
    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

        SentrySDK.start { options in
            options.dsn = "https://4c25b7d4a50eb8ed2d44b674901d44fc@o4511547810840576.ingest.de.sentry.io/4511547871723600"
            options.environment = "production"
            options.tracesSampleRate = 1.0
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    updaterController.checkForUpdates(nil)
                }
            }
        }
    }
}
