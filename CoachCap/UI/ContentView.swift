import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var licenseManager = LicenseManager.shared
    @State private var showTranslocationAlert = false
    @State private var showHelp = false
    @State private var helpIsFirstRun = false
    /// Set once we've auto-shown the "how it works" guide, so it only pops up the first launch.
    @AppStorage("hasSeenGuide") private var hasSeenGuide = false

    var body: some View {
        if showTranslocationAlert {
            translocatedAlert
        } else if !licenseManager.isUnlocked {
            // No active licence (trial or paid) → the whole app is behind the trial. This is the
            // single gate: recording, the WhatsApp browser, before/after and export are all
            // unreachable until a trial is started, so no feature can be used for free.
            trialWall
                .onAppear { checkTranslocation() }
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
            .sheet(isPresented: $showHelp) {
                HelpGuideView(isPresented: $showHelp, firstRun: helpIsFirstRun)
            }
            .onAppear {
                checkTranslocation()
                // Auto-show the guide once, the first time someone reaches the unlocked app.
                if !hasSeenGuide {
                    hasSeenGuide = true
                    helpIsFirstRun = true
                    showHelp = true
                }
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

            // "?" help button — parks on the right, clear of the centred tabs.
            HStack {
                Spacer()
                Button {
                    helpIsFirstRun = false
                    showHelp = true
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 17))
                        .foregroundStyle(Brand.muted)
                }
                .buttonStyle(.plain)
                .help("how coachcam works")
                .padding(.trailing, 16)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(Brand.bg)
        .overlay(Rectangle().fill(Brand.border).frame(height: 1), alignment: .bottom)
    }

    /// Shown when there's no active licence — the trial gate for the whole app.
    private var trialWall: some View {
        ZStack {
            Brand.bg.ignoresSafeArea()
            VStack(spacing: 20) {
                Text("coachcam")
                    .font(Brand.font(38, .bold))
                    .foregroundStyle(Brand.text)
                Text("better client check-ins — free for \(LicenseManager.trialDays) days")
                    .font(Brand.font(16))
                    .foregroundStyle(Brand.muted)

                VStack(alignment: .leading, spacing: 10) {
                    wallBullet("record your screen + face in one clip")
                    wallBullet("compare check-in photos side by side, live")
                    wallBullet("pull client photos straight from whatsapp")
                    wallBullet("works fully offline")
                }
                .padding(.top, 6)

                LicenseView(licenseManager: licenseManager)
                    .frame(maxWidth: 440)
                    .padding(.top, 8)
            }
            .frame(maxWidth: 480)
            .padding(40)
        }
        .frame(minWidth: 1120, idealWidth: 1240, minHeight: 700, idealHeight: 780)
    }

    private func wallBullet(_ text: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.accent)
            Text(text).font(Brand.font(14)).foregroundStyle(Brand.text)
            Spacer()
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
