import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var showTranslocationAlert = false

    var body: some View {
        if showTranslocationAlert {
            translocatedAlert
        } else {
            VStack(spacing: 0) {
                topTabBar
                // Both views stay alive (keeps the camera session running) — we just
                // show/hide them so switching tabs is instant and stateful.
                ZStack {
                    RecordingView()
                        .opacity(appState.activeTab == .recorder ? 1 : 0)
                        .allowsHitTesting(appState.activeTab == .recorder)
                    PhotoToolView()
                        .opacity(appState.activeTab == .photoTool ? 1 : 0)
                        .allowsHitTesting(appState.activeTab == .photoTool)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: 1120, idealWidth: 1240, minHeight: 700, idealHeight: 780)
            .background(Brand.bg)
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

    /// Top bar with the shared brand segmented control (sits in the hidden-title-bar area;
    /// centred so it clears the traffic-light buttons on the left).
    private var topTabBar: some View {
        ZStack {
            BrandSegmented(selection: $appState.activeTab, options: [
                ("record", AppTab.recorder),
                ("before / after", AppTab.photoTool)
            ])
            .frame(width: 300)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(Brand.bg)
        .overlay(Rectangle().fill(Brand.border).frame(height: 1), alignment: .bottom)
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
