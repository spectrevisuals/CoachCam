import SwiftUI
import AVFoundation
import ScreenCaptureKit

// Models
import Foundation

struct RecordingView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var session = RecordingSession()
    @StateObject private var camera  = CameraManager()
    @ObservedObject private var licenseManager = LicenseManager.shared

    @State private var showSavedBanner = false
    @State private var floatingPanel: FloatingCameraPanel? = nil
    @State private var showLowStorageAlert = false
    @State private var freeGBText = ""
    @State private var showQuotaAlert = false

    /// The window we hid for the current recording, so we can bring it back on stop.
    @State private var recordingWindow: NSWindow? = nil
    /// Retains the custom-area selector overlay while the coach is drawing the box.
    @State private var areaSelector: AreaSelectorController? = nil
    /// Persistent orange outline showing the active custom area on screen.
    @State private var areaIndicator: AreaIndicatorWindow? = nil

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
        // Whenever recording ends — via stop, the float cam, or the free-tier timeout —
        // bring the main window back to the front so the "send to whatsapp" banner is
        // immediately reachable (and so an auto-hidden window can't get stranded).
        .onChange(of: session.isRunning) { _, running in
            if !running { restoreMainWindow() }
        }
        // Keep the on-screen custom-area outline in sync with the selection.
        .onChange(of: appState.customArea) { _, _ in refreshAreaIndicator() }
        .onDisappear { areaIndicator?.orderOut(nil); areaIndicator = nil }
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
        .alert("Monthly limit reached", isPresented: $showQuotaAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Free accounts can make \(FreeTier.maxRecordingsPerMonth) recordings per calendar month, and you've used them all. Your count resets on the 1st. Upgrade for unlimited recordings.")
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
                            icon: session.isRunning ? "record.circle.fill"
                                : (appState.customArea != nil ? "rectangle.dashed" : "desktopcomputer"),
                            title: session.isRunning ? "recording…"
                                : (appState.customArea != nil ? "custom area + face cam" : "screen + face cam"),
                            subtitle: appState.customArea != nil
                                ? "only the area you drew is recorded — look for the orange outline on screen"
                                : "your screen is recorded directly — no preview needed",
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
                        Text("· free · \(remaining)s left")
                            .font(Brand.font(11, .semibold))
                            .foregroundStyle(remaining <= 10 ? Brand.danger : Brand.accent2)
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
            VStack(spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(hex: 0x28C840))
                    Text("recording saved").font(Brand.font(14, .semibold)).foregroundStyle(Brand.text)
                    Spacer()
                    Button { withAnimation { showSavedBanner = false } } label: {
                        Image(systemName: "xmark").font(.system(size: 11)).foregroundStyle(Brand.muted)
                    }
                    .buttonStyle(.plain)
                }
                if let url = appState.lastSavedURL {
                    HStack(spacing: 10) {
                        WhatsAppShareButton(url: url,
                                            clientName: appState.whatsAppClientName
                                                ?? (appState.clientName.isEmpty ? nil : appState.clientName))
                        Button("show in finder") { ExportManager.revealInFinder(url) }
                            .buttonStyle(OutlineButtonStyle())
                    }
                    Text("drag the highlighted video from finder into your whatsapp chat")
                        .font(Brand.font(11))
                        .foregroundStyle(Brand.muted)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(16)
            .frame(width: 380)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: Brand.rPanel, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Brand.rPanel, style: .continuous).stroke(Brand.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
            .padding(.bottom, 24)
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

            // Custom area (Loom-style drag-a-box capture). Hidden in webcam-only mode.
            if !appState.webcamOnlyMode {
                Button { toggleCustomArea() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: appState.customArea == nil ? "rectangle.dashed" : "rectangle.dashed.badge.record")
                        Text(customAreaLabel)
                    }
                }
                .buttonStyle(OutlineButtonStyle(active: appState.customArea != nil))
                .disabled(session.isRunning)
                .help("Record only a custom area of the screen. Click to drag a box; click again to clear.")
            }

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
                if !session.isRunning {
                    appState.webcamOnlyMode.toggle()
                    if appState.webcamOnlyMode { clearCustomArea() }   // custom area is screen-only
                }
            }
            segItem("mirror", active: camera.mirrorEnabled, icon: "arrow.left.and.right") {
                camera.mirrorEnabled.toggle()
                session.updateMirror(camera.mirrorEnabled)
            }
            segItem("auto-hide", active: appState.hideWindowWhileRecording, icon: "macwindow") {
                if !session.isRunning { appState.hideWindowWhileRecording.toggle() }
            }
            .help("Hide the CoachCam window when recording starts — handy for talking over Google Sheets or Photos. Pair it with float cam so you can still stop.")
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

        // Free-tier monthly recording cap (gated on the single licence source).
        if !licenseManager.isUnlocked && !RecordingQuota.canRecord() {
            showQuotaAlert = true
            return
        }

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

        // A custom area (Loom-style) crops the capture to the drawn box; otherwise capture
        // the selected monitor at its own aspect ratio (webcam-only keeps the 16:9 frame).
        let usingCustomArea = !appState.webcamOnlyMode && appState.customArea != nil
        let chosenDisplay = DisplayList.option(for: appState.selectedDisplayID)
        let videoSize: CGSize = {
            if appState.webcamOnlyMode { return CGSize(width: 1920, height: 1080) }
            if usingCustomArea, let px = appState.customAreaPixelSize { return px }
            return chosenDisplay?.recommendedOutputSize ?? CGSize(width: 1920, height: 1080)
        }()

        // Prefer the client picked in the WhatsApp photo tool so the file is named after
        // them and easy to find; fall back to the manual client-name field.
        let clientForFile: String = {
            if let w = appState.whatsAppClientName?.trimmingCharacters(in: .whitespaces), !w.isEmpty { return w }
            return appState.clientName
        }()

        let config = RecordingConfig(
            outputURL: RecordingConfig.autoOutputURL(clientName: clientForFile),
            videoSize: videoSize,
            pipNormalizedRect: appState.pipRect,
            selectedMicID: appState.selectedMicID,
            displayID: appState.webcamOnlyMode ? nil : (usingCustomArea ? appState.customAreaDisplayID : chosenDisplay?.id),
            sourceRect: usingCustomArea ? appState.customArea : nil
        )
        Task {
            do {
                try await session.start(config: config, camera: camera,
                                        isLicensed: licenseManager.isUnlocked,
                                        cameraFloating: floatingPanel != nil)
                appState.isRecording = true
                appState.startTimer()
                hideMainWindowForRecording()
                // Count this recording against the free monthly quota (paid = unlimited).
                if !licenseManager.isUnlocked { RecordingQuota.recordOne() }
            } catch {
                appState.errorMessage = error.localizedDescription
            }
        }
    }

    private func stopAndSave() {
        appState.isSaving = true
        appState.stopTimer()
        appState.isRecording = false
        // Always bring the window back on stop, in every mode (also handled by the
        // isRunning observer, but do it here too so it's immediate and guaranteed).
        restoreMainWindow()
        Task {
            // session.stop() awaits finishWriting, so `url` points to a fully-written file.
            let url = await session.stop()
            appState.lastSavedURL = url
            appState.isSaving = false
            // Persist the banner — it holds the "send to whatsapp" action — until dismissed.
            withAnimation { showSavedBanner = true }
        }
    }

    // MARK: Window hide / restore

    /// The main content window (the titled SwiftUI window), never the floating cam panel.
    private func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.styleMask.contains(.titled) && !($0 is FloatingCameraPanel) }
    }

    /// Get the main window out of the way as recording starts (when the toggle is on).
    /// We *minimise* rather than orderOut: hiding the window can make SwiftUI tear down
    /// this view and kill the recording session mid-capture. Minimising keeps the window
    /// (and the live recording) alive, and leaves a Dock thumbnail to click back to.
    /// Skipped in webcam-only mode, where the window itself is what's being recorded.
    private func hideMainWindowForRecording() {
        guard appState.hideWindowWhileRecording, !appState.webcamOnlyMode else { return }
        if let win = mainWindow() {
            recordingWindow = win
            win.miniaturize(nil)
        }
    }

    /// Bring the main window back to the front and focus the app. Safe to call on any
    /// stop — if the window was never hidden it simply surfaces it for the save banner.
    private func restoreMainWindow() {
        let win = recordingWindow ?? mainWindow()
        recordingWindow = nil
        guard let win else { return }
        if win.isMiniaturized { win.deminiaturize(nil) }
        win.setIsVisible(true)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Custom area

    private var customAreaLabel: String {
        if let px = appState.customAreaPixelSize {
            return "area \(Int(px.width))×\(Int(px.height))"
        }
        return "custom area"
    }

    /// Click to draw a box; click again (when one is set) to clear back to full screen.
    private func toggleCustomArea() {
        guard !session.isRunning else { return }
        if appState.customArea != nil { clearCustomArea(); return }

        let screen = screenForSelectedDisplay() ?? NSScreen.main
        guard let screen else { return }
        let scale = screen.backingScaleFactor
        let selector = AreaSelectorController { rect, displayID in
            guard let rect, let displayID else { return }   // Esc / too-small = cancelled
            appState.customArea = rect
            appState.customAreaDisplayID = displayID
            appState.customAreaPixelSize = Self.evenPixelSize(rect.size, scale: scale)
            appState.webcamOnlyMode = false   // custom area is a screen mode
            areaSelector = nil
        }
        areaSelector = selector
        selector.present(on: screen)
    }

    private func clearCustomArea() {
        appState.customArea = nil
        appState.customAreaDisplayID = nil
        appState.customAreaPixelSize = nil
    }

    private func screenForSelectedDisplay() -> NSScreen? {
        screen(forDisplayID: appState.selectedDisplayID)
    }

    private func screen(forDisplayID id: CGDirectDisplayID?) -> NSScreen? {
        if let id {
            return NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
            }
        }
        return NSScreen.main
    }

    /// Show / move / hide the persistent orange outline to match the current custom area.
    private func refreshAreaIndicator() {
        areaIndicator?.orderOut(nil)
        areaIndicator = nil
        guard let rect = appState.customArea,
              let screen = screen(forDisplayID: appState.customAreaDisplayID) else { return }
        let win = AreaIndicatorWindow(screen: screen, rect: rect)
        win.orderFront(nil)
        areaIndicator = win
    }

    /// H.264 needs even dimensions — round the region's pixel size to the nearest even values.
    private static func evenPixelSize(_ pointSize: CGSize, scale: CGFloat) -> CGSize {
        func even(_ v: CGFloat) -> CGFloat { let i = Int((v * scale).rounded()); return CGFloat(max(2, i - (i % 2))) }
        return CGSize(width: even(pointSize.width), height: even(pointSize.height))
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
                onCancelCountdown: { cancelCountdown() },
                onCustomArea: { toggleCustomArea() }
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
