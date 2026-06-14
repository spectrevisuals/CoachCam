import SwiftUI
import Sparkle

@main
struct CoachCapApp: App {
    @StateObject private var appState = AppState()

    // Sparkle: starts the updater, which performs scheduled background checks
    // (gated by SUEnableAutomaticChecks in Info.plist) and drives in-place updates
    // that preserve the app's identity — so camera/screen permissions carry over.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
    )

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
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }
    }
}
