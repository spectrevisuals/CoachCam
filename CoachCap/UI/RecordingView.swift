import SwiftUI
import AVFoundation
import ScreenCaptureKit

// Models
import Foundation

struct RecordingView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var session = RecordingSession()
    @StateObject private var camera  = CameraManager()
    @StateObject private var licenseManager = LicenseManager()

    @State private var showSavedBanner = false
    @State private var floatingPanel: FloatingCameraPanel? = nil

    private var isOnMacOS15OrLater: Bool {
        if #available(macOS 15.0, *) {
            return true
        }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            LicenseView(licenseManager: licenseManager)
            Divider()
            previewArea
            Divider()
            controlBar
        }
        .onAppear {
            NSLog("DEBUG RecordingView: camera ID = \(ObjectIdentifier(camera))")
            Task { await session.checkPermission() }
            camera.startCapture(cameraID: appState.selectedCameraID)
        }
        .onChange(of: appState.selectedCameraID) { _, id in
            camera.startCapture(cameraID: id)
        }
        .onChange(of: session.errorMessage) { _, msg in
            if let msg { appState.errorMessage = msg }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notif in
            if notif.object as AnyObject === floatingPanel {
                cancelCountdown()
                floatingPanel = nil
            }
        }
    }

    // MARK: Preview

    @ViewBuilder
    private var previewArea: some View {
        ZStack {
            Color.black

            if appState.webcamOnlyMode {
                CameraPreviewView(camera: camera)
                    .aspectRatio(16/9, contentMode: .fit)
            } else {
                // Screen placeholder + PiP overlay
                screenPreviewWithPiP
            }

            // Permission warning - only on macOS 14 and earlier
            if !session.permissionGranted && !appState.webcamOnlyMode && !isOnMacOS15OrLater {
                VStack {
                    Spacer()
                    VStack(spacing: 10) {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                            Text("Enable Screen Recording")
                                .font(.caption)
                                .foregroundColor(.orange)
                            Spacer()
                        }
                        Text("Go to System Settings > Privacy & Security > Screen Recording and enable CoachCam, then click Relaunch.")
                            .font(.caption2)
                            .foregroundColor(.orange)
                        Button("Open Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }
                        .font(.caption)
                        Button("Relaunch CoachCam") {
                            let task = Process()
                            task.executableURL = URL(fileURLWithPath: "/bin/sh")
                            task.arguments = ["-c", "sleep 0.5; open '\(Bundle.main.bundlePath)'"]
                            try? task.run()
                            NSApplication.shared.terminate(nil)
                        }
                        .font(.caption)
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(8)
                    .background(Color.black.opacity(0.7))
                }
            }

            // Recording indicator
            if session.isRunning {
                recordingIndicator
            }

            // Saved banner
            if showSavedBanner {
                savedBanner
            }

            // Countdown overlay
            if let count = appState.countdownValue {
                countdownOverlay(count)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.25), value: appState.countdownValue)
    }

    private var screenPreviewWithPiP: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Screen placeholder (actual screen is being captured, not previewed here)
                Color(NSColor.windowBackgroundColor)
                    .overlay(
                        VStack(spacing: 12) {
                            Image(systemName: session.isRunning ? "record.circle.fill" : "display")
                                .font(.system(size: 48))
                                .foregroundColor(session.isRunning ? .red : .secondary)
                            Text(session.isRunning
                                 ? "Recording your screen…"
                                 : "Screen + face cam mode")
                                .foregroundColor(.secondary)
                        }
                    )

                // Draggable PiP box
                PiPOverlayView(camera: camera,
                               pipRect: $appState.pipRect,
                               canvasSize: geo.size,
                               onChanged: { session.updatePiP($0) })
            }
        }
    }

    private var permissionOverlay: some View {
        ZStack {
            Color.black.opacity(0.75)
            VStack(spacing: 16) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 48))
                    .foregroundColor(.orange)
                Text("Screen Recording Access Required")
                    .font(.headline).foregroundColor(.white)
                Text("Enable CoachCap in System Settings → Privacy & Security → Screen Recording, then click Check Again.")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white.opacity(0.8))
                    .frame(maxWidth: 420)

                // Show raw error so we can diagnose
                if let err = session.errorMessage {
                    Text(err)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.yellow.opacity(0.8))
                        .frame(maxWidth: 460)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 12) {
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                    Button("Check Again") {
                        Task { await session.checkPermission() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(40)
        }
    }

    private var recordingIndicator: some View {
        VStack {
            HStack {
                Spacer()
                HStack(spacing: 8) {
                    Circle()
                        .fill(session.isPaused ? Color.orange : Color.red)
                        .frame(width: 10, height: 10)
                    Text(session.isPaused ? "PAUSED" : timerString)
                        .font(.system(.caption, design: .monospaced).bold())
                        .foregroundColor(.white)
                    if let remaining = session.recordingTimeRemaining {
                        Spacer()
                        Text("Free: \(remaining)s left")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(remaining < 10 ? .red : .white.opacity(0.7))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.6))
                .clipShape(Capsule())
                .padding(12)
            }
            Spacer()
        }
    }

    private var savedBanner: some View {
        VStack {
            Spacer()
            HStack {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                Text("Saved to Movies/CoachCap")
                if let url = appState.lastSavedURL {
                    Button("Show in Finder") { ExportManager.revealInFinder(url) }
                        .buttonStyle(.link)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([url as NSURL])
                    }
                    .buttonStyle(.link)
                }
            }
            .padding()
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.bottom, 20)
        }
    }

    // MARK: Control Bar

    private var controlBar: some View {
        HStack(spacing: 20) {
            // Client name
            TextField("Client name (optional)", text: $appState.clientName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .disabled(session.isRunning)

            Divider().frame(height: 32)

            // Source pickers
            cameraPicker
            micPicker

            Divider().frame(height: 32)

            // Mode toggle
            Toggle("Webcam only", isOn: $appState.webcamOnlyMode)
                .disabled(session.isRunning)
                .toggleStyle(.checkbox)

            Toggle("Mirror", isOn: $camera.mirrorEnabled)
                .toggleStyle(.checkbox)
                .onChange(of: camera.mirrorEnabled) { _, mirrored in
                    session.updateMirror(mirrored)
                }

            // Floating cam toggle
            Button(floatingPanel != nil ? "Dock Cam" : "Float Cam") {
                toggleFloatingCam()
            }
            .buttonStyle(BigButtonStyle(color: floatingPanel != nil ? .secondary : .blue))

            Spacer()

            // Main action buttons
            if session.isRunning {
                // Pause/Resume
                Button(session.isPaused ? "Resume" : "Pause") {
                    if session.isPaused { session.resume(); appState.isPaused = false; appState.resumeTimer() }
                    else               { session.pause();  appState.isPaused = true;  appState.pauseTimer()  }
                }
                .buttonStyle(BigButtonStyle(color: .orange))
                .keyboardShortcut("p")

                // Stop
                Button("Stop & Save") { stopAndSave() }
                    .buttonStyle(BigButtonStyle(color: .red))
                    .keyboardShortcut(".")
            } else {
                Button(appState.isSaving ? "Saving…" : "● Record") { startWithCountdown() }
                    .buttonStyle(BigButtonStyle(color: .red))
                    .disabled(appState.isSaving || appState.countdownValue != nil || (!session.permissionGranted && !appState.webcamOnlyMode))
                    .keyboardShortcut("r")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var cameraPicker: some View {
        Picker("Camera", selection: $appState.selectedCameraID) {
            Text("Default").tag(String?.none)
            ForEach(camera.availableCameras, id: \.uniqueID) { dev in
                Text(dev.localizedName).tag(Optional(dev.uniqueID))
            }
        }
        .labelsHidden()
        .frame(width: 160)
        .disabled(session.isRunning)
    }

    private var micPicker: some View {
        Picker("Microphone", selection: $appState.selectedMicID) {
            Text("Default mic").tag(String?.none)
            ForEach(camera.availableMics, id: \.uniqueID) { dev in
                Text(dev.localizedName).tag(Optional(dev.uniqueID))
            }
        }
        .labelsHidden()
        .frame(width: 160)
        .disabled(session.isRunning)
    }

    // MARK: Actions

    private func startWithCountdown() {
        guard !appState.isSaving, appState.countdownValue == nil else { return }

        // On macOS 15+ in screen+cam mode, present system picker
        if isOnMacOS15OrLater && !appState.webcamOnlyMode {
            if #available(macOS 15.0, *) {
                SCContentSharingPicker.shared.isActive = true
                NSLog("DEBUG: SCContentSharingPicker activated")
            }
            startRecording()
            return
        }

        appState.countdownTask = Task { @MainActor in
            for i in stride(from: 3, through: 1, by: -1) {
                appState.countdownValue = i
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { appState.countdownValue = nil; return }
            }
            appState.countdownValue = nil
            guard !Task.isCancelled else { return }
            startRecording()
        }
    }

    private func cancelCountdown() {
        appState.countdownTask?.cancel()
        appState.countdownTask = nil
        appState.countdownValue = nil
    }

    private func startRecording() {
        guard !appState.isSaving else { return }
        let config = RecordingConfig(
            outputURL: RecordingConfig.autoOutputURL(clientName: appState.clientName),
            videoSize: CGSize(width: 1920, height: 1080),
            pipNormalizedRect: appState.pipRect,
            selectedMicID: appState.selectedMicID
        )
        Task {
            do {
                try await session.start(config: config, camera: camera, isLicensed: licenseManager.isUnlocked)
                appState.isRecording = true
                appState.startTimer()
            } catch {
                appState.errorMessage = error.localizedDescription
            }
        }
    }

    private func stopAndSave() {
        appState.isSaving = true
        appState.stopTimer()
        appState.isRecording = false
        Task {
            let url = await session.stop()
            appState.lastSavedURL = url
            appState.isSaving = false
            withAnimation { showSavedBanner = true }
            try? await Task.sleep(for: .seconds(4))
            withAnimation { showSavedBanner = false }
        }
    }

    private func toggleFloatingCam() {
        if let panel = floatingPanel {
            panel.close()
            floatingPanel = nil
        } else {
            let panel = FloatingCameraPanel(
                camera: camera,
                appState: appState,
                onStart: { startWithCountdown() },
                onPauseResume: {
                    if session.isPaused { session.resume(); appState.isPaused = false; appState.resumeTimer() }
                    else               { session.pause();  appState.isPaused = true;  appState.pauseTimer()  }
                },
                onStop: { stopAndSave() },
                onCancelCountdown: { cancelCountdown() }
            )
            panel.orderFront(nil)
            floatingPanel = panel
        }
    }

    private func countdownOverlay(_ count: Int) -> some View {
        ZStack {
            Color.black.opacity(0.55)
            Text("\(count)")
                .font(.system(size: 120, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.3), radius: 12)
                .id(count)
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.6).combined(with: .opacity),
                    removal:   .scale(scale: 1.4).combined(with: .opacity)
                ))
        }
    }

    private var timerString: String {
        let d = Int(appState.recordingDuration)
        return String(format: "%02d:%02d", d / 60, d % 60)
    }
}

// MARK: - Draggable PiP Overlay

private struct PiPOverlayView: View {
    @ObservedObject var camera: CameraManager
    @Binding var pipRect: CGRect
    let canvasSize: CGSize
    let onChanged: (CGRect) -> Void

    @State private var dragOffset: CGSize = .zero

    var body: some View {
        let px = pipRect.origin.x * canvasSize.width  + dragOffset.width
        let py = pipRect.origin.y * canvasSize.height + dragOffset.height
        let pw = pipRect.width    * canvasSize.width
        let ph = pipRect.height   * canvasSize.height

        ZStack {
            // Camera feed inside the box
            Group {
                if let frame = camera.currentFrame {
                    Image(nsImage: NSImage(ciImage: frame))
                        .resizable()
                        .scaledToFill()
                        .clipped()
                } else {
                    Color.gray.opacity(0.5)
                        .overlay(Image(systemName: "video.fill")
                            .foregroundColor(.white.opacity(0.5)))
                }
            }
            .frame(width: pw, height: ph)
            .clipShape(RoundedRectangle(cornerRadius: pw * 0.08))
            .overlay(RoundedRectangle(cornerRadius: pw * 0.08)
                .stroke(Color.white.opacity(0.6), lineWidth: 2))

            // Drag handle hint
            Image(systemName: "move.3d")
                .foregroundColor(.white.opacity(0.7))
                .font(.system(size: 18))
        }
        .position(x: px + pw / 2, y: py + ph / 2)
        .gesture(
            DragGesture()
                .onChanged { value in dragOffset = value.translation }
                .onEnded { value in
                    let newX = (pipRect.origin.x * canvasSize.width  + value.translation.width)  / canvasSize.width
                    let newY = (pipRect.origin.y * canvasSize.height + value.translation.height) / canvasSize.height
                    pipRect = CGRect(
                        x: max(0, min(newX, 1 - pipRect.width)),
                        y: max(0, min(newY, 1 - pipRect.height)),
                        width: pipRect.width,
                        height: pipRect.height
                    )
                    dragOffset = .zero
                    onChanged(pipRect)
                }
        )
    }
}

// MARK: - Styles

private struct BigButtonStyle: ButtonStyle {
    var color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .background(color.opacity(configuration.isPressed ? 0.7 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private extension NSImage {
    convenience init(ciImage: CIImage) {
        let rep = NSCIImageRep(ciImage: ciImage)
        self.init(size: rep.size)
        addRepresentation(rep)
    }
}
