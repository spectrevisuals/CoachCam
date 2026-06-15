import SwiftUI
import Sparkle
import CoreText

@main
struct CoachCapApp: App {
    @StateObject private var appState = AppState()

    init() {
        // Register the bundled Quicksand font so SwiftUI's Font.custom("Quicksand") works.
        if let url = Bundle.main.url(forResource: "Quicksand", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

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
                .background(Brand.bg.ignoresSafeArea())
                .brandTheme()
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
