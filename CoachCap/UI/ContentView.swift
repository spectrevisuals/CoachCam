import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var showTranslocationAlert = false

    var body: some View {
        if showTranslocationAlert {
            translocatedAlert
        } else {
            TabView(selection: $appState.activeTab) {
                RecordingView()
                    .tabItem { Label("Record", systemImage: "record.circle.fill") }
                    .tag(AppTab.recorder)

                PhotoToolView()
                    .tabItem { Label("Before / After", systemImage: "photo.on.rectangle.angled") }
                    .tag(AppTab.photoTool)
            }
            .frame(minWidth: 960, idealWidth: 1100, minHeight: 640, idealHeight: 720)
            .alert("Error", isPresented: Binding(
                get: { appState.errorMessage != nil },
                set: { if !$0 { appState.errorMessage = nil } }
            )) {
                Button("OK") { appState.errorMessage = nil }
            } message: {
                Text(appState.errorMessage ?? "")
            }
            .onAppear {
                checkTranslocation()
            }
        }
    }

    private var translocatedAlert: some View {
        VStack(spacing: 20) {
            Text("Move CoachCam to Applications")
                .font(.headline)
            Text("CoachCam must be in /Applications to access screen recording. Please move the app and relaunch.")
                .multilineTextAlignment(.center)
            Button("Open Applications Folder") {
                NSWorkspace.shared.open(FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask)[0])
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(width: 400, height: 200)
    }

    private func checkTranslocation() {
        let bundlePath = Bundle.main.bundlePath
        if bundlePath.contains("/AppTranslocation/") {
            showTranslocationAlert = true
        }
    }
}
