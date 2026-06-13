import SwiftUI

@main
struct CoachCapApp: App {
    @StateObject private var appState = AppState()
    // @StateObject private var updateChecker = UpdateChecker() // TODO: fix build target
    // @State private var showUpdateAlert = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
        // TODO: Re-enable auto-update checking once build target is fixed
        // .onAppear { updateChecker.checkForUpdates() }
        // .onChange(of: updateChecker.updateAvailable) { newValue in if newValue != nil { showUpdateAlert = true } }
        // .alert("Update Available", isPresented: $showUpdateAlert) { ... }
    }
}
