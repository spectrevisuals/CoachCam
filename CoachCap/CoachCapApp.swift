import SwiftUI

@main
struct CoachCapApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var updateChecker = UpdateChecker()
    @State private var showUpdateAlert = false

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
        .onAppear {
            updateChecker.checkForUpdates()
        }
        .onChange(of: updateChecker.updateAvailable) { newValue in
            if newValue != nil {
                showUpdateAlert = true
            }
        }
        .alert("Update Available", isPresented: $showUpdateAlert) {
            if let update = updateChecker.updateAvailable {
                Button("Download") {
                    if let url = URL(string: update.url) {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Cancel", role: .cancel) { }
            }
        } message: {
            if let update = updateChecker.updateAvailable {
                Text("CoachCam v\(update.version) is available. Download the latest version?")
            }
        }
    }
}
