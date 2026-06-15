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
    @State private var showLowStorageAlert = false
    @State private var freeGBText = ""

    /// Recordings use roughly 30 MB/minute; warn below ~2 GB so a coach never loses a
    /// check-in to a full disk.
    private static let minFreeBytes: Int64 = 2_000_000_000
    private static func freeDiskBytes() -> Int64? {
        let url = (try? FileManager.default.url(for: .moviesDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: false))
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    private var isOnMacOS15OrLater: Bool {
        if #available(macOS 15.0, *) {
            return true
        }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            LicenseView(licenseManager: licenseManager)
            previewArea
            controlBar
        }
        .onAppear {
            NSLog("DEBUG RecordingView: camera ID = \(ObjectIdentifier(camera))")
            Task { await session.checkPermission() }
            camera.startCapture(cameraID: appState.selectedCameraID)
            if appState.selectedDisplayID == nil {
                appState.selectedDisplayID = DisplayList.available().first?.id
            }
        }
        .task {
            // Confirm/refresh the subscription in the background; never gates launch.
            await licenseManager.validateOnLaunch()
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
                session.setCameraFloating(false)
            }
        }
        .alert("Low disk space", isPresented: $showLowStorageAlert) {
            Button("Record anyway") { beginCountdown() }
            Button("Open Storage Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Only \(freeGBText) GB free on this Mac. Recordings use about 30 MB per minute, so a long check-in could fail and be lost. Free up some space to be safe.")
        }
    }

    // MARK: Preview

    @ViewBuilder
    private var previewArea: some View {
        ZStack {
            Brand.bg
            RadialGradient(colors: [Brand.accent.opacity(0.09), .clear],
                           center: UnitPoint(x: 0.5, y: 0.4), startRadius: 0, endRadius: 360)
                .allowsHitTesting(false)

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
                Color.clear
                    .overlay(
                        BrandEmptyState(
                            icon: session.isRunning ? "record.circle.fill" : "desktopcomputer",
                            title: session.isRunning ? "recording your screen…" : "screen + face cam",
                            subtitle: "your screen appears here when you hit record",
                            iconSize: 26, boxSize: 60)
                    )

                // Draggable PiP box — hidden while the cam is floating, otherwise the
                // main window would show (and record) a second copy of the face cam.
                if floatingPanel == nil {
                    PiPOverlayView(camera: camera,
                                   pipRect: $appState.pipRect,
                                   canvasSize: geo.size,
                                   onChanged: { session.updatePiP($0) })
                }
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
        HStack(spacing: 12) {
            // Client name
            TextField("client name (optional)", text: $appState.clientName)
                .textFieldStyle(.plain)
                .font(Brand.font(13))
                .foregroundStyle(Brand.text)
                .frame(maxWidth: .infinity)
                .brandPill()
                .disabled(session.isRunning)

            // Source dropdowns
            cameraPill
            micPill
            if !appState.webcamOnlyMode && availableDisplays.count > 1 {
                displayPill
            }

            // Webcam-only / mirror segmented control
            segmentedModes

            // Floating cam
            Button { toggleFloatingCam() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "pip")
                    Text(floatingPanel != nil ? "dock cam" : "float cam")
                }
            }
            .buttonStyle(OutlineButtonStyle(active: floatingPanel != nil))

            // Main action
            if session.isRunning {
                Button { togglePause() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: session.isPaused ? "play.fill" : "pause.fill")
                        Text(session.isPaused ? "resume" : "pause")
                    }
                }
                .buttonStyle(PrimaryButtonStyle(color: Brand.accent))
                .keyboardShortcut("p")

                Button { stopAndSave() } label: {
                    HStack(spacing: 7) { Image(systemName: "stop.fill"); Text("stop & save") }
                }
                .buttonStyle(PrimaryButtonStyle(color: Brand.danger))
                .keyboardShortcut(".")
            } else {
                Button { startWithCountdown() } label: {
                    HStack(spacing: 8) {
                        Circle().fill(.white).frame(width: 9, height: 9)
                        Text(appState.isSaving ? "saving…" : "record")
                    }
                }
                .buttonStyle(PrimaryButtonStyle(color: Brand.danger))
                .disabled(appState.isSaving || appState.countdownValue != nil || (!session.permissionGranted && !appState.webcamOnlyMode))
                .keyboardShortcut("r")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .background(.ultraThinMaterial)
        .overlay(Rectangle().fill(Brand.border).frame(height: 1), alignment: .top)
    }

    // MARK: Styled dropdown pills

    private var cameraPill: some View {
        dropdownPill(icon: "video", label: selectedCameraLabel,
                     selection: $appState.selectedCameraID,
                     options: [("default camera", String?.none)]
                        + camera.availableCameras.map { ($0.localizedName, Optional($0.uniqueID)) })
    }

    private var micPill: some View {
        dropdownPill(icon: "mic", label: selectedMicLabel,
                     selection: $appState.selectedMicID,
                     options: [("default mic", String?.none)]
                        + camera.availableMics.map { ($0.localizedName, Optional($0.uniqueID)) })
    }

    private var displayPill: some View {
        dropdownPill(icon: "display", label: selectedDisplayLabel,
                     selection: $appState.selectedDisplayID,
                     options: availableDisplays.map { ($0.label, Optional($0.id)) })
    }

    /// Styled dropdown. The pill styling lives INSIDE the menu label (with a hit-testable
    /// content shape) so the whole pill is clickable, and options are Buttons so selection
    /// is reliable — wrapping a Menu in an outer .frame/.background broke click handling.
    private func dropdownPill<T: Hashable>(icon: String, label: String,
                                           selection: Binding<T>,
                                           options: [(String, T)]) -> some View {
        Menu {
            ForEach(options, id: \.1) { opt in
                Button {
                    selection.wrappedValue = opt.1
                } label: {
                    if selection.wrappedValue == opt.1 {
                        Label(opt.0, systemImage: "checkmark")
                    } else {
                        Text(opt.0)
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 14)).foregroundStyle(Brand.muted)
                Text(label).font(Brand.font(13)).foregroundStyle(Brand.text.opacity(0.85)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 10)).foregroundStyle(Brand.muted)
            }
            .frame(height: Brand.controlHeight)
            .padding(.horizontal, 13)
            .background(RoundedRectangle(cornerRadius: Brand.rControl, style: .continuous).fill(Brand.control))
            .overlay(RoundedRectangle(cornerRadius: Brand.rControl, style: .continuous).stroke(Brand.controlBorder, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(session.isRunning)
    }

    private var segmentedModes: some View {
        HStack(spacing: 3) {
            segItem("webcam only", active: appState.webcamOnlyMode, icon: nil) {
                if !session.isRunning { appState.webcamOnlyMode.toggle() }
            }
            segItem("mirror", active: camera.mirrorEnabled, icon: "arrow.left.and.right") {
                camera.mirrorEnabled.toggle()
                session.updateMirror(camera.mirrorEnabled)
            }
        }
        .padding(3)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: Brand.radius, style: .continuous).fill(Brand.control))
        .overlay(RoundedRectangle(cornerRadius: Brand.radius, style: .continuous).stroke(Brand.controlBorder, lineWidth: 1))
    }

    private func segItem(_ title: String, active: Bool, icon: String?, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 13)) }
                Text(title).font(Brand.font(12, active ? .semibold : .medium))
            }
            .foregroundStyle(active ? Brand.text : Brand.muted)
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(active ? Brand.accentSoft : Color.clear))
        }
        .buttonStyle(.plain)
    }

    private var availableDisplays: [DisplayOption] { DisplayList.available() }

    private func togglePause() {
        if session.isPaused { session.resume(); appState.isPaused = false; appState.resumeTimer() }
        else               { session.pause();  appState.isPaused = true;  appState.pauseTimer()  }
    }

    private var selectedCameraLabel: String {
        if let id = appState.selectedCameraID,
           let d = camera.availableCameras.first(where: { $0.uniqueID == id }) { return d.localizedName }
        return "default"
    }
    private var selectedMicLabel: String {
        if let id = appState.selectedMicID,
           let d = camera.availableMics.first(where: { $0.uniqueID == id }) { return d.localizedName }
        return "default mic"
    }
    private var selectedDisplayLabel: String {
        if let id = appState.selectedDisplayID,
           let d = availableDisplays.first(where: { $0.id == id }) { return d.label }
        return "screen"
    }

    // MARK: Actions

    private func startWithCountdown() {
        guard !appState.isSaving, appState.countdownValue == nil else { return }

        // Storage safety check — don't let a coach lose a check-in to a full disk.
        if let free = Self.freeDiskBytes(), free < Self.minFreeBytes {
            freeGBText = String(format: "%.1f", Double(free) / 1_000_000_000)
            showLowStorageAlert = true
            return
        }
        beginCountdown()
    }

    private func beginCountdown() {
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

        // Capture the selected monitor at its own aspect ratio (webcam-only mode
        // keeps the standard 16:9 frame).
        let chosenDisplay = DisplayList.option(for: appState.selectedDisplayID)
        let videoSize = appState.webcamOnlyMode
            ? CGSize(width: 1920, height: 1080)
            : (chosenDisplay?.recommendedOutputSize ?? CGSize(width: 1920, height: 1080))

        let config = RecordingConfig(
            outputURL: RecordingConfig.autoOutputURL(clientName: appState.clientName),
            videoSize: videoSize,
            pipNormalizedRect: appState.pipRect,
            selectedMicID: appState.selectedMicID,
            displayID: appState.webcamOnlyMode ? nil : chosenDisplay?.id
        )
        Task {
            do {
                try await session.start(config: config, camera: camera,
                                        isLicensed: licenseManager.isUnlocked,
                                        cameraFloating: floatingPanel != nil)
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
            session.setCameraFloating(false)
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
            session.setCameraFloating(true)
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
                if let frame = camera.previewImage {
                    Image(decorative: frame, scale: 1, orientation: .up)
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
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.85), lineWidth: 1.5))
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 4) {
                    Circle().fill(Color(hex: 0x28C840)).frame(width: 6, height: 6)
                    Text("face cam").font(Brand.font(10, .medium)).foregroundStyle(.white)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.black.opacity(0.5)))
                .padding(9)
            }

            // Drag handle hint
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .foregroundColor(.white.opacity(0.6))
                .font(.system(size: 15))
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

private extension NSImage {
    convenience init(ciImage: CIImage) {
        let rep = NSCIImageRep(ciImage: ciImage)
        self.init(size: rep.size)
        addRepresentation(rep)
    }
}
