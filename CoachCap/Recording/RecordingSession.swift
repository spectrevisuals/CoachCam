import Foundation
import ScreenCaptureKit
import AVFoundation

import CoreMedia
import CoreGraphics
import Combine
import AppKit

// MARK: - RecordingSession

/// Coordinates SCStream (screen + system audio), AVCaptureSession (mic),
/// FrameCompositor (PiP burn-in), and AVAssetWriter (H.264/AAC output).
///
/// Concurrency model:
///   • @MainActor for all published state and public API.
///   • Encode-pipeline objects are nonisolated(unsafe) — written once from
///     main actor before the stream starts, then read from encode queues.
///   • Mutable encode-thread state lives in `CS` (CaptureState), always
///     accessed under `captureLock`.
@MainActor
final class RecordingSession: NSObject, ObservableObject {

    // MARK: Published (main actor)
    @Published var isRunning = false
    @Published var isPaused  = false
    @Published var permissionGranted = false
    @Published var errorMessage: String?
    @Published var recordingTimeRemaining: Int? = nil // nil = unlimited, else seconds left

    private var freeTimerTask: Task<Void, Never>?

    // MARK: Encode-pipeline (nonisolated — written before stream starts)
    nonisolated(unsafe) private let compositor = FrameCompositor()
    nonisolated(unsafe) private var writer:      AVAssetWriter?
    nonisolated(unsafe) private var vidInput:    AVAssetWriterInput?
    nonisolated(unsafe) private var sysAudInput:AVAssetWriterInput?
    nonisolated(unsafe) private var micAudInput: AVAssetWriterInput?
    nonisolated(unsafe) private var adaptor:     AVAssetWriterInputPixelBufferAdaptor?
    nonisolated(unsafe) private var _camera:     CameraManager?

    // Per-track timeline continuity + sample counts. Each is touched only by its own capture
    // queue (video/sysaud/mic), so no lock is needed. We drop any sample whose adjusted PTS is
    // non-numeric, negative, or not advancing — a stalling/re-enumerating external device can
    // emit duplicate, backwards or NaN timestamps, which otherwise make finishWriting fail and
    // lose the whole recording. Counts let us spot an empty track at finalize.
    nonisolated(unsafe) private var lastVideoPTS  = CMTime.negativeInfinity
    nonisolated(unsafe) private var lastSysEndPTS = CMTime.negativeInfinity
    nonisolated(unsafe) private var lastMicEndPTS = CMTime.negativeInfinity
    nonisolated(unsafe) private var videoSampleCount = 0
    nonisolated(unsafe) private var sysAudioSampleCount = 0
    nonisolated(unsafe) private var micSampleCount = 0
    // Audio-timing diagnostics (audio-speed bug): actual sample rates from the buffers' format
    // descriptions, total PCM sample counts, and the first adjusted PTS per audio track. From
    // these the effective rate (totalSamples / timelineSpan) can be checked against the tagged
    // rate to catch a sample-rate/clock mismatch. Purely observational — no behaviour change.
    nonisolated(unsafe) private var sysAudioHz: Double = 0
    nonisolated(unsafe) private var micAudioHz: Double = 0
    nonisolated(unsafe) private var sysSampleTotal: Int64 = 0
    nonisolated(unsafe) private var micSampleTotal: Int64 = 0
    nonisolated(unsafe) private var sysFirstPTS = CMTime.invalid
    nonisolated(unsafe) private var micFirstPTS = CMTime.invalid
    /// `ProcessInfo.systemUptime` of the last mic sample, for the device watchdog (0 until the
    /// first sample). Lets us notice a mic that stops sending audio within a few seconds,
    /// rather than waiting ~10s for macOS to post the USB-disconnect notification.
    nonisolated(unsafe) private var lastMicSampleAt: Double = 0

    // MARK: Mutable encode-thread state (always under captureLock)
    private let captureLock = NSLock()
    nonisolated(unsafe) private var cs = CS()

    private struct CS {
        // Single shared zero used by ALL streams so they stay in sync.
        // Set from whichever sample (video, system audio, or mic) arrives first.
        var tZero: CMTime? = nil
        var pauseStart: CMTime? = nil
        var totalPaused: CMTime = .zero
        var isPaused: Bool      = false
        var pipRect   = CGRect(x: 0.72, y: 0.04, width: 0.24, height: 0.24)
        var outputSize = CGSize(width: 1920, height: 1080)
        // When the floating cam window is up, it IS the on-screen face cam (captured by
        // the screen recording), so we must NOT also burn a PiP — otherwise the camera
        // shows up twice in the saved video.
        var cameraFloating = false
        // Set once a writer append/finish failure is seen, so we log the underlying
        // writer.error only once instead of on every subsequent dropped sample.
        var loggedWriterFailure = false
    }

    private nonisolated func locked<T>(_ work: (inout CS) -> T) -> T {
        captureLock.lock(); defer { captureLock.unlock() }
        return work(&cs)
    }

    /// True if the writer has entered a failed state. Logs the underlying error exactly once
    /// (subsequent dropped samples stay quiet) so a mid-recording failure is visible without
    /// spamming the log on every frame.
    private nonisolated func writerDidFail() -> Bool {
        guard let w = writer, w.status == .failed else { return false }
        let shouldLog = locked { s -> Bool in
            if s.loggedWriterFailure { return false }
            s.loggedWriterFailure = true
            return true
        }
        if shouldLog {
            NSLog("ERROR: AVAssetWriter failed mid-recording: \(String(describing: w.error))")
            // Stop and alert NOW, at the moment of failure — don't let the coach keep filming
            // against a dead writer and only discover at the end that little was captured.
            Task { @MainActor [weak self] in await self?.endUnexpectedly() }
        }
        return true
    }

    /// Shared capture teardown. Does NOT touch `isRunning` — each caller decides when to flip
    /// it (the user path flips immediately for snappy UI; unexpected-stop paths flip last, so
    /// the finalized result is ready when RecordingView reacts).
    private func teardownCapture() async {
        isPaused = false
        lastVideoAdvanceAt = 0
        lastVideoCount = 0
        simulateStallDeadline = 0
        freeTimerTask?.cancel()
        recordingTimeRemaining = nil
        watchdogTask?.cancel(); watchdogTask = nil
        removeCaptureObservers()
        try? await stream?.stopCapture()
        stream = nil
        micSession?.stopRunning()
        micSession = nil
        if let token = sleepAssertion {
            ProcessInfo.processInfo.endActivity(token)
            sleepAssertion = nil
        }
    }

    // MARK: - Capture-device interruption (external cam/mic dropping mid-recording)

    /// Observes the events that fire when a capture device drops or its session breaks: a
    /// physical disconnect (USB pull), a session runtime error, or a session interruption —
    /// for BOTH the microphone session and the camera session. Any of these mid-recording
    /// means the recording is compromised, so we stop and salvage immediately rather than let
    /// the coach keep filming against a dead device and lose everything at finalize.
    private func installCaptureObservers() {
        removeCaptureObservers()
        let nc = NotificationCenter.default
        let camDeviceID = _camera?.activeCameraDevice?.uniqueID
        let micDeviceID = micDevice?.uniqueID

        // Physical disconnect of any capture device — match against the cam/mic in use.
        captureObservers.append(nc.addObserver(
            forName: .AVCaptureDeviceWasDisconnected, object: nil, queue: .main
        ) { [weak self] note in
            let id = (note.object as? AVCaptureDevice)?.uniqueID
            let which: String? = (id != nil && id == micDeviceID) ? "microphone"
                               : (id != nil && id == camDeviceID) ? "camera" : nil
            guard let which else { return }
            Task { @MainActor [weak self] in self?.captureInterrupted("Your \(which) disconnected.") }
        })

        // Session-level runtime errors / interruptions on the mic and camera sessions.
        for (session, label) in [(micSession, "microphone"), (_camera?.activeSession, "camera")] {
            guard let session else { continue }
            captureObservers.append(nc.addObserver(
                forName: .AVCaptureSessionRuntimeError, object: session, queue: .main
            ) { [weak self] note in
                let err = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
                Task { @MainActor [weak self] in
                    self?.captureInterrupted("Your \(label) stopped working (\(err?.localizedDescription ?? "device error")).")
                }
            })
            captureObservers.append(nc.addObserver(
                forName: .AVCaptureSessionWasInterrupted, object: session, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.captureInterrupted("Your \(label) was interrupted.") }
            })
        }
    }

    private func removeCaptureObservers() {
        captureObservers.forEach { NotificationCenter.default.removeObserver($0) }
        captureObservers.removeAll()
    }

    /// Catches a dropped external device fast: a yanked USB cam/mic simply STOPS calling its
    /// delegate — there's no immediate error, and macOS can take ~10s to post the disconnect
    /// notification. So we poll data-arrival times and trip the interruption ourselves once a
    /// device that WAS delivering goes quiet. Thresholds are generous to avoid false positives
    /// from brief hiccups; the OS notification remains a backstop.
    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.isRunning, self.pendingInterruptionReason == nil else { continue }
                let now = ProcessInfo.processInfo.systemUptime
                // Video-stall guard. The screen feed can silently stop delivering frames (no
                // error), so the recording captures nothing yet "looks" like it's running — this
                // is how a long check-in gets lost. Watch the frame count: reset the timer each
                // time it advances; if it hasn't moved for `videoStallSeconds`, capture is dead —
                // stop and tell the coach, instead of filming the whole session into the void.
                // Catches both "no frames ever" and "died after a couple of frames".
                if !self.isPaused, self.lastVideoAdvanceAt > 0 {
                    if self.videoSampleCount != self.lastVideoCount {
                        self.lastVideoCount = self.videoSampleCount
                        self.lastVideoAdvanceAt = now
                    } else {
                        // Zero frames from the start is unambiguously dead capture (even a static
                        // screen yields a first frame instantly) → catch fast. A few frames then
                        // frozen could be a momentary hiccup → give it the full window.
                        let limit = self.videoSampleCount == 0 ? 8.0 : self.videoStallSeconds
                        if now - self.lastVideoAdvanceAt > limit {
                            self.captureInterrupted("CoachCam stopped receiving screen video from your Mac.")
                            continue
                        }
                    }
                }
                // Mic was delivering audio, now silent for >3s.
                if self.lastMicSampleAt > 0, now - self.lastMicSampleAt > 3 {
                    self.captureInterrupted("Your microphone stopped sending audio.")
                    continue
                }
                // Camera session running and was delivering frames, now frozen for >5s.
                if let cam = self._camera, cam.activeSession?.isRunning == true,
                   cam.lastFrameAt > 0, now - cam.lastFrameAt > 5 {
                    self.captureInterrupted("Your camera stopped sending video.")
                }
            }
        }
    }

    /// A capture device dropped mid-recording: record the reason and end the session now,
    /// salvaging whatever was filmed. Guarded so only the first event acts.
    private func captureInterrupted(_ reason: String) {
        guard isRunning, pendingInterruptionReason == nil else { return }
        pendingInterruptionReason = reason
        NSLog("WARN: capture interrupted mid-recording — \(reason)")
        Self.appendErrorLog("capture interrupted mid-recording — \(reason)")
        DiagnosticsReporter.report("🟠 recording interrupted",
            detail: "\(reason)\nsamples[video=\(videoSampleCount) sys=\(sysAudioSampleCount) mic=\(micSampleCount)]")
        Task { await endUnexpectedly() }
    }

    /// Ends a recording that stopped on its own (writer failure, stream interruption, free-tier
    /// timeout): tears down, salvages whatever was filmed, THEN flips `isRunning` so
    /// RecordingView reads the finalized clip + reason and ends the session immediately.
    private func endUnexpectedly() async {
        guard isRunning else { return }
        await teardownCapture()
        _ = await finalizeWriter()
        isRunning = false
    }

    // MARK: Infrastructure (main actor only)
    private var stream:     SCStream?
    private var micSession: AVCaptureSession?
    private var micDevice:  AVCaptureDevice?
    private var outputURL:  URL?

    // Observers for capture-device disconnects / session interruptions (external USB cam or
    // mic dropping mid-recording). Torn down with the capture.
    private var captureObservers: [NSObjectProtocol] = []
    // Polls camera/mic data-arrival times so a dropped device is caught in ~3-5s instead of
    // waiting for macOS's (often ~10s) USB-disconnect notification.
    private var watchdogTask: Task<Void, Never>?
    // Video-stall detection. The screen feed (SCStream) can silently die — stop delivering
    // frames with NO error callback — leaving the app "recording" nothing for the whole session
    // and losing it at finalize. We watch the video frame count: if it stops advancing for
    // `videoStallSeconds`, capture is dead and we stop + warn instead of losing a long check-in.
    // This catches both "no frames ever" (count stuck at 0) and "died after a few frames".
    private var lastVideoCount: Int = 0
    private var lastVideoAdvanceAt: Double = 0
    private let videoStallSeconds: Double = 20
    // DEV/TEST ONLY: when the hidden key `simulateVideoStallAfterSeconds` is set, stop feeding
    // the writer video after that many seconds — reproduces a silent SCStream death so the
    // stall-watchdog can be verified without touching permissions. 0 = off (normal behaviour).
    nonisolated(unsafe) private var simulateStallDeadline: Double = 0
    // Set when capture is interrupted by a device drop, so finalize can tell the coach why.
    private var pendingInterruptionReason: String?

    // Held for the whole recording so macOS won't sleep the display / nap the (often
    // minimised) app mid-capture — either of which interrupts the SCStream and leaves a
    // half-written, unplayable file. Ended on stop and on interruption.
    private var sleepAssertion: NSObjectProtocol?

    // finalizeWriter() runs at most once per recording; the outcome is cached so a stop()
    // after an interruption-driven finalise returns the salvaged URL instead of re-running.
    private var didFinalize  = false
    private(set) var finalizedURL: URL?

    // Human-readable reason the last save failed (e.g. "Not enough disk space"), so the UI
    // can show the actual cause instead of a generic "try again". nil when the last save
    // succeeded. Read by RecordingView after stop() returns nil.
    private(set) var lastSaveError: String?

    // Set when a recording was saved but cut short (salvaged partial) — the coach kept a clip
    // but should know it stopped early and why. nil for a clean full recording.
    private(set) var lastSavePartialNote: String?

    private let vidQueue = DispatchQueue(label: "com.coachcap.vid",   qos: .userInteractive)
    private let audQueue = DispatchQueue(label: "com.coachcap.sysaud", qos: .userInteractive)
    private let micQueue = DispatchQueue(label: "com.coachcap.mic",   qos: .userInteractive)

    // MARK: - Permissions

    func checkPermission() async {
        // On macOS 15+, skip TCC checks — use picker instead
        if #available(macOS 15.0, *) {
            permissionGranted = true
            errorMessage = nil
            return
        }

        // Legacy path for macOS 14 and earlier
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        NSLog("DEBUG: checkPermission() called - Bundle ID: \(bundleID)")

        if CGPreflightScreenCaptureAccess() {
            NSLog("DEBUG: Screen recording permission already granted")
            permissionGranted = true
            errorMessage = nil
            return
        }

        CGRequestScreenCaptureAccess()
        permissionGranted = false
        errorMessage = "Screen recording requires permission. Please enable in System Settings > Privacy & Security > Screen Recording, then relaunch CoachCam."
    }

    // MARK: - Start

    func start(config: RecordingConfig, camera: CameraManager, isLicensed: Bool, cameraFloating: Bool = false) async throws {
        guard !isRunning else { return }

        _camera    = camera
        outputURL  = config.outputURL

        // Free tier: cap recording length. Gated on the single licence source (isLicensed
        // is passed straight from LicenseManager.shared.isUnlocked).
        if !isLicensed {
            startFreeRecordingTimer()
        } else {
            recordingTimeRemaining = nil
        }
        cs = CS()   // reset state
        didFinalize = false
        finalizedURL = nil
        lastSaveError = nil
        lastSavePartialNote = nil
        pendingInterruptionReason = nil
        lastVideoPTS = .negativeInfinity
        lastSysEndPTS = .negativeInfinity
        lastMicEndPTS = .negativeInfinity
        videoSampleCount = 0; sysAudioSampleCount = 0; micSampleCount = 0
        sysAudioHz = 0; micAudioHz = 0; sysSampleTotal = 0; micSampleTotal = 0
        sysFirstPTS = .invalid; micFirstPTS = .invalid
        // Sync the burned-in mirror with the live setting. Without this the compositor keeps
        // its default (off) unless the user happens to toggle the mirror button, so the saved
        // video wouldn't mirror even though the preview (and the toggle) say it should.
        compositor.mirrorCamera = camera.mirrorEnabled
        locked {
            $0.pipRect    = config.pipNormalizedRect
            $0.outputSize = config.videoSize
            $0.cameraFloating = cameraFloating   // set before any frame is processed
        }

        try setupWriter(config: config)

        // Resolve which monitor to capture. config.displayID picks a specific
        // display; nil falls back to the primary. (macOS 14's call may trigger
        // the TCC permission dialog.)
        let display: SCDisplay
        do {
            let content: SCShareableContent
            if #available(macOS 15.0, *) {
                content = try await SCShareableContent.current
            } else {
                content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            }
            NSLog("DEBUG: SCShareableContent succeeded. Displays: \(content.displays.count)")
            guard let chosen = content.displays.first(where: { $0.displayID == config.displayID })
                    ?? content.displays.first else {
                NSLog("ERROR: No displays found")
                throw CCError.noDisplay
            }
            display = chosen
        } catch {
            NSLog("ERROR: SCShareableContent failed - \(error.localizedDescription)")
            throw error
        }
        NSLog("DEBUG: Using display id \(display.displayID) (\(display.width)×\(display.height))")

        NSLog("DEBUG: Creating SCContentFilter...")
        let filter = SCContentFilter(display: display,
                                     excludingApplications: [],
                                     exceptingWindows: [])

        NSLog("DEBUG: Creating SCStreamConfiguration...")
        let cfg = SCStreamConfiguration()
        cfg.width  = Int(config.videoSize.width)
        cfg.height = Int(config.videoSize.height)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.frameRate))
        cfg.capturesAudio = true
        cfg.sampleRate    = 44100
        cfg.channelCount  = 2
        cfg.pixelFormat   = kCVPixelFormatType_32BGRA

        // Custom area: capture only the chosen sub-rect of the display. sourceRect is in
        // points; width/height stay at the region's pixel size for a 1:1, undistorted crop.
        if let sr = config.sourceRect {
            cfg.sourceRect = sr
        }

        NSLog("DEBUG: Creating SCStream...")
        let sc = SCStream(filter: filter, configuration: cfg, delegate: self)
        NSLog("DEBUG: SCStream created: \(sc)")

        do {
            NSLog("DEBUG: Adding screen output...")
            try sc.addStreamOutput(self, type: .screen, sampleHandlerQueue: vidQueue)
            NSLog("DEBUG: Screen output added successfully")
        } catch {
            NSLog("ERROR: Failed to add screen output - \(error)")
            throw error
        }

        do {
            NSLog("DEBUG: Adding audio output...")
            try sc.addStreamOutput(self, type: .audio, sampleHandlerQueue: audQueue)
            NSLog("DEBUG: Audio output added successfully")
        } catch {
            NSLog("ERROR: Failed to add audio output - \(error)")
            throw error
        }

        // Make sure microphone access has actually been requested. Without this the app
        // is never added to the Privacy → Microphone list, the capture session yields no
        // samples, and the voice track is silent/missing. Prompt on first use; wait so the
        // grant is in place before the mic session starts.
        // Prompt for microphone on first use so the voice track is actually captured.
        // (Requires the `com.apple.security.device.audio-input` hardened-runtime entitlement —
        // without it macOS blocks the mic before the prompt ever shows.)
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        setupMicCapture(deviceID: config.selectedMicID)
        lastMicSampleAt = 0
        installCaptureObservers()

        NSLog("DEBUG: Starting AVAssetWriter...")
        writer?.startWriting()
        // Bail loudly if the writer never entered .writing — otherwise capture would run
        // against a dead writer and silently produce an unplayable file.
        if let w = writer, w.status != .writing {
            NSLog("ERROR: AVAssetWriter failed to start — status \(w.status.rawValue): \(String(describing: w.error))")
            throw w.error ?? CCError.writerSetupFailed
        }

        NSLog("DEBUG: Calling sc.startCapture()...")
        do {
            try await sc.startCapture()
            NSLog("DEBUG: sc.startCapture() succeeded")
        } catch {
            let nsError = error as NSError
            NSLog("ERROR: sc.startCapture() failed - Domain: \(nsError.domain), Code: \(nsError.code), Message: \(nsError.localizedDescription)")
            throw error
        }

        stream = sc

        // Keep the display awake and the app off App Nap for the whole recording. A long
        // check-in with the window minimised is exactly when macOS would otherwise sleep
        // the display and interrupt the SCStream, leaving a half-written file.
        sleepAssertion = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .idleDisplaySleepDisabled],
            reason: "CoachCam recording in progress")

        isRunning = true
        isPaused  = false
        lastVideoCount = 0
        lastVideoAdvanceAt = ProcessInfo.processInfo.systemUptime
        let simSecs = UserDefaults.standard.integer(forKey: "simulateVideoStallAfterSeconds")
        simulateStallDeadline = simSecs > 0 ? ProcessInfo.processInfo.systemUptime + Double(simSecs) : 0
        startWatchdog()
        // Note any active camera video-effects (Reactions/Portrait/etc.) — they can't be
        // disabled programmatically but can destabilise capture, so record them for triage.
        let fx = camera.activeCameraEffects()
        if !fx.isEmpty {
            NSLog("WARN: recording started with active camera effects: \(fx.joined(separator: ", "))")
            Self.appendErrorLog("recording started with active camera effects: \(fx.joined(separator: ", "))")
        }
        NSLog("DEBUG: Recording started successfully")
    }

    // MARK: - Pause / Resume

    func pause() {
        guard isRunning, !isPaused else { return }
        isPaused = true
        let t = CMClockGetTime(CMClockGetHostTimeClock())
        locked { $0.isPaused = true; $0.pauseStart = t }
    }

    func resume() {
        guard isRunning, isPaused else { return }
        isPaused = false
        // Don't let paused time count toward the video-stall timeout.
        lastVideoCount = videoSampleCount
        lastVideoAdvanceAt = ProcessInfo.processInfo.systemUptime
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        locked {
            if let ps = $0.pauseStart {
                $0.totalPaused = CMTimeAdd($0.totalPaused, CMTimeSubtract(now, ps))
            }
            $0.isPaused = false
            $0.pauseStart = nil
        }
    }

    // MARK: - Free tier timer

    private func startFreeRecordingTimer() {
        freeTimerTask?.cancel()
        let cap = FreeTier.maxRecordingSeconds
        recordingTimeRemaining = cap
        freeTimerTask = Task { @MainActor in
            for second in stride(from: cap, through: 1, by: -1) {
                if Task.isCancelled { break }
                recordingTimeRemaining = second
                try? await Task.sleep(for: .seconds(1))
            }
            // Time's up — auto stop with a clear message. Set the message first so the
            // unexpected-stop handler keeps it (it only fills a blank message).
            if isRunning {
                errorMessage = "free recordings are capped at \(cap / 60) minutes — upgrade for unlimited"
                await endUnexpectedly()
            }
        }
    }

    // MARK: - Stop

    func stop() async -> URL? {
        // User-initiated stop: flip isRunning immediately for snappy UI (the saved/saving
        // state is driven by RecordingView, which already set isRecording=false, so the
        // unexpected-stop handler won't double-fire), then tear down and finalise.
        isRunning = false
        await teardownCapture()
        return await finalizeWriter()
    }

    /// Finishes the asset writer and returns the output URL only if a valid, non-trivial
    /// file landed on disk. On failure it logs the writer error, removes the broken stub so
    /// it can't masquerade as a real recording, and returns nil so the UI can surface an error.
    private func finalizeWriter() async -> URL? {
        // Idempotent: an interrupted stream finalises here, and a follow-up stop() must
        // return the same result instead of re-running finishWriting (which would delete
        // the file we just salvaged).
        if didFinalize { return finalizedURL }
        didFinalize = true
        var result = await performFinalize()
        // Merge system-audio + mic into one track so the clip isn't silent in WhatsApp (which
        // plays only the first audio track). Also cleans up a fragmented partial into a normal
        // mp4. No-ops on a single-track file; returns the original on failure. Done here (not
        // in stop()) so EVERY exit — user stop, writer failure, interruption — yields a single,
        // sendable, fully-finalised file.
        if let raw = result {
            result = await ExportManager.flattenAudioTracks(inputURL: raw)
        }
        finalizedURL = result
        return result
    }

    private func performFinalize() async -> URL? {
        guard let w = writer, let url = outputURL else {
            fail(reason: "The recorder never started.", url: outputURL, error: nil)
            return nil
        }

        // Only finishWriting if still writing; a failed writer can't be finished, but its
        // fragmented file on disk may still hold a playable partial we can salvage.
        if w.status == .writing {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                w.finishWriting { cont.resume() }
            }
        }

        // Log the REAL outcome — status, error, the hidden underlying error (AVAssetWriter
        // usually reports a generic -11800 and buries the actual CoreMedia code under
        // NSUnderlyingErrorKey), plus per-track sample counts to spot a dropped/empty track.
        let underlying = (w.error as NSError?)?.userInfo[NSUnderlyingErrorKey]
        // Audio-timing diagnostics: effective rate = total PCM samples / timeline span. If it
        // differs from the tagged/ASBD rate, that's the sample-rate/clock mismatch behind the
        // audio-speed bug (e.g. audio ~2/3 of video ⇒ effHz ~2/3 of 44100).
        let spanSys = (sysFirstPTS.isNumeric && lastSysEndPTS.isNumeric) ? CMTimeGetSeconds(CMTimeSubtract(lastSysEndPTS, sysFirstPTS)) : 0
        let spanMic = (micFirstPTS.isNumeric && lastMicEndPTS.isNumeric) ? CMTimeGetSeconds(CMTimeSubtract(lastMicEndPTS, micFirstPTS)) : 0
        let effSys = spanSys > 0 ? Double(sysSampleTotal) / spanSys : 0
        let effMic = spanMic > 0 ? Double(micSampleTotal) / spanMic : 0
        let audioDiag = " audioHz[sys=\(Int(sysAudioHz)) mic=\(Int(micAudioHz))]"
            + " audioSamples[sys=\(sysSampleTotal) mic=\(micSampleTotal)]"
            + " spanS[sys=\(String(format: "%.1f", spanSys)) mic=\(String(format: "%.1f", spanMic))]"
            + " effHz[sys=\(Int(effSys)) mic=\(Int(effMic))]"
        let diag = "finalize status=\(w.status.rawValue) error=\(String(describing: w.error)) underlying=\(String(describing: underlying)) samples[video=\(videoSampleCount) sys=\(sysAudioSampleCount) mic=\(micSampleCount)]" + audioDiag
        NSLog("DEBUG: \(diag)")
        Self.appendErrorLog(diag)

        let interrupted = pendingInterruptionReason

        // Clean, fully-finalised recording.
        if w.status == .completed,
           let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 1024 {
            lastSaveError = nil
            // A clean finish is still a SHORTENED recording if a device dropped — tell the coach.
            if let why = interrupted, let secs = await usablePartialDuration(url) {
                lastSavePartialNote = "Recording stopped — \(why) Saved the \(Self.durationString(secs)) recorded before it stopped."
            } else {
                lastSavePartialNote = nil
            }
            return url
        }

        // Not clean — but because we record in fragments, the file on disk is usually playable
        // up to the last fragment. Salvage it as a partial clip instead of losing everything.
        let reason = interrupted ?? describeWriterError(w.error)
        if let secs = await usablePartialDuration(url) {
            lastSaveError = nil
            lastSavePartialNote = "Recording stopped — \(reason) Recovered the \(Self.durationString(secs)) that was filmed."
            NSLog("WARN: recording salvaged as partial (\(Self.durationString(secs))) — \(reason)")
            Self.appendErrorLog("salvaged partial (\(Self.durationString(secs))) — \(reason)")
            return url   // finalizeWriter's remux/flatten turns the fragmented partial into a clean clip
        }

        // Nothing usable on disk.
        fail(reason: reason, url: url, error: w.error)
        return nil
    }

    /// Returns the duration (seconds) of the file if it's a usable partial — i.e. it has a
    /// video track and at least ~1s of content. nil if there's nothing worth keeping.
    private func usablePartialDuration(_ url: URL) async -> Double? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = AVURLAsset(url: url)
        guard let dur = try? await asset.load(.duration) else { return nil }
        let secs = CMTimeGetSeconds(dur)
        guard secs.isFinite, secs >= 1 else { return nil }
        let videos = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        return videos.isEmpty ? nil : secs
    }

    static func durationString(_ secs: Double) -> String {
        let s = Int(secs.rounded())
        return s >= 60 ? "\(s / 60)m \(s % 60)s" : "\(s)s"
    }

    /// Records a save failure: builds a clear reason (with free-disk-space context), sets
    /// `lastSaveError` for the UI, appends it to a findable log file the coach can send, and
    /// PRESERVES the partial file (renamed `.unfinished.mp4`) instead of deleting it — so a
    /// lost check-in has at least a chance of recovery and we can inspect what went wrong.
    private func fail(reason: String, url: URL?, error: Error?) {
        let free = freeDiskSpaceString()
        let full = "\(reason) (Free disk space: \(free).)"
        lastSaveError = full
        NSLog("ERROR: recording failed to save — \(full) — writer.error=\(String(describing: error))")
        Self.appendErrorLog("save failed — \(full) | writer.error=\(String(describing: error))")
        DiagnosticsReporter.report("🔴 recording SAVE FAILED",
            detail: "\(full)\nsamples[video=\(videoSampleCount) sys=\(sysAudioSampleCount) mic=\(micSampleCount)]\nwriter.error=\(String(describing: error))")

        // Preserve the partial: rename to .unfinished.mp4 so it doesn't masquerade as a good
        // recording but is still there for recovery/inspection.
        if let url, FileManager.default.fileExists(atPath: url.path) {
            let kept = url.deletingPathExtension().appendingPathExtension("unfinished.mp4")
            try? FileManager.default.removeItem(at: kept)
            try? FileManager.default.moveItem(at: url, to: kept)
        }
    }

    /// Turns an AVAssetWriter error into a coach-friendly sentence, flagging the disk-full
    /// case specifically. Digs into the underlying error too: AVAssetWriter usually reports a
    /// generic AVErrorUnknown (-11800) and hides the real cause (e.g. a CoreMedia sample-timing
    /// error like -12737) under NSUnderlyingErrorKey — we surface both so failures are
    /// diagnosable from the in-app message / log without Console.
    private func describeWriterError(_ error: Error?) -> String {
        guard let e = error as NSError? else { return "The recording couldn't be finalized." }
        let underlying = e.userInfo[NSUnderlyingErrorKey] as? NSError
        let diskFull = isDiskFull(e) || underlying.map(isDiskFull) == true
        if diskFull { return "Your Mac ran out of disk space while saving." }
        var msg = "The recording couldn't be finalized (\(e.localizedDescription)) [\(e.domain) \(e.code)"
        if let u = underlying { msg += " / underlying \(u.domain) \(u.code)" }
        msg += "]."
        return msg
    }

    private func isDiskFull(_ e: NSError) -> Bool {
        (e.domain == NSPOSIXErrorDomain && e.code == 28)            // ENOSPC
            || (e.domain == NSCocoaErrorDomain && e.code == 640)    // NSFileWriteOutOfSpaceError
            || (e.domain == AVFoundationErrorDomain && e.code == -11807)  // AVError.diskFull
            || e.localizedDescription.lowercased().contains("disk")
    }

    /// Free space on the recording's volume, human-readable (e.g. "1.2 GB").
    private func freeDiskSpaceString() -> String {
        let probe = outputURL ?? (try? FileManager.default.url(for: .moviesDirectory, in: .userDomainMask,
                                                               appropriateFor: nil, create: false))
        if let probe,
           let vals = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let bytes = vals.volumeAvailableCapacityForImportantUsage {
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        return "unknown"
    }

    /// Appends a timestamped line to ~/Movies/CoachCap/CoachCam-error-log.txt so the coach can
    /// find and send it without using Terminal.
    nonisolated static func appendErrorLog(_ message: String) {
        guard let dir = try? FileManager.default.url(for: .moviesDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: false)
            .appendingPathComponent("CoachCap", isDirectory: true) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let logURL = dir.appendingPathComponent("CoachCam-error-log.txt")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let line = "[\(stamp)] v\(ver): \(message)\n"
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    // MARK: - PiP live update (main actor)

    func updatePiP(_ rect: CGRect) {
        locked { $0.pipRect = rect }
    }

    func updateMirror(_ mirrored: Bool) {
        compositor.mirrorCamera = mirrored
    }

    /// Tells the recorder whether the face cam is currently a floating on-screen window.
    /// While floating, the burned-in PiP is suppressed so the camera isn't recorded twice.
    func setCameraFloating(_ floating: Bool) {
        locked { $0.cameraFloating = floating }
    }

    // MARK: - Private setup

    /// The selected mic's actual hardware sample rate (Hz), read from its active format, so we
    /// can write audio at its native rate rather than assuming 44100. Falls back to 44100 if it
    /// can't be read or looks invalid.
    nonisolated static func deviceAudioRate(micID: String?) -> Double {
        let dev = micID.flatMap { AVCaptureDevice(uniqueID: $0) } ?? AVCaptureDevice.default(for: .audio)
        if let fmt = dev?.activeFormat.formatDescription,
           CMFormatDescriptionGetMediaType(fmt) == kCMMediaType_Audio,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) {
            let hz = asbd.pointee.mSampleRate
            if hz >= 8000, hz <= 192000 { return hz }
        }
        return 44100
    }

    private func setupWriter(config: RecordingConfig) throws {
        let w = try AVAssetWriter(outputURL: config.outputURL, fileType: .mp4)
        // Write the movie in periodic fragments. This makes the file on disk playable up to
        // the last fragment even if the writer dies mid-recording or the app is killed — so a
        // failed/interrupted check-in can be salvaged into a clip instead of lost entirely.
        w.movieFragmentInterval = CMTime(value: 5, timescale: 1)   // flush every ~5s

        let videoSettings: [String: Any] = [
            AVVideoCodecKey:  AVVideoCodecType.h264,
            AVVideoWidthKey:  Int(config.videoSize.width),
            AVVideoHeightKey: Int(config.videoSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey:          RecordingConfig.videoBitrate(for: config.videoSize),
                AVVideoProfileLevelKey:            AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: config.frameRate,
                AVVideoMaxKeyFrameIntervalKey:     config.frameRate,
                AVVideoAllowFrameReorderingKey:    false,
            ] as [String: Any]
        ]
        let vi = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vi.expectsMediaDataInRealTime = true
        let adp = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vi,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey  as String: Int(config.videoSize.width),
                kCVPixelBufferHeightKey as String: Int(config.videoSize.height),
            ])

        // Write audio at the mic's ACTUAL hardware rate instead of assuming 44100. Most Macs'
        // built-in mics (and SCStream system audio) run at 48000; forcing 44100 relied on
        // AVAssetWriter silently resampling — fragile, and tied to the audio-speed bug. Reading
        // the real rate keeps the timeline native (a no-op where the device is already 44100).
        // Resampling always preserves duration, so this can never introduce a speed change.
        let audioHz = Self.deviceAudioRate(micID: config.selectedMicID)
        let audioSettings: [String: Any] = [
            AVFormatIDKey:         kAudioFormatMPEG4AAC,
            AVSampleRateKey:       audioHz,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey:   RecordingConfig.audioBitrate,
        ]
        let sa = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        sa.expectsMediaDataInRealTime = true
        let ma = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        ma.expectsMediaDataInRealTime = true

        if w.canAdd(vi) { w.add(vi) }
        if w.canAdd(sa) { w.add(sa) }
        if w.canAdd(ma) { w.add(ma) }

        writer = w; vidInput = vi; sysAudInput = sa; micAudInput = ma; adaptor = adp
    }

    private func setupMicCapture(deviceID: String?) {
        let s = AVCaptureSession()
        s.beginConfiguration()
        let mic = deviceID.flatMap { AVCaptureDevice(uniqueID: $0) }
               ?? AVCaptureDevice.default(for: .audio)
        micDevice = mic
        if let m = mic, let inp = try? AVCaptureDeviceInput(device: m), s.canAddInput(inp) {
            s.addInput(inp)
        }
        let out = AVCaptureAudioDataOutput()
        out.setSampleBufferDelegate(self, queue: micQueue)
        if s.canAddOutput(out) { s.addOutput(out) }
        s.commitConfiguration()
        micSession = s
        micQueue.async { s.startRunning() }
    }
}

// MARK: - SCStreamDelegate

extension RecordingSession: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("ERROR: SCStream stopped with error: \(error.localizedDescription)")
        Task { @MainActor [weak self] in
            // Only react to an *unexpected* stop. A normal user stop() already flipped
            // isRunning to false and is finalising itself. endUnexpectedly() salvages what was
            // filmed and surfaces it via RecordingView's unexpected-stop handler.
            await self?.endUnexpectedly()
        }
    }
}

// MARK: - SCStreamOutput

extension RecordingSession: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream,
                             didOutputSampleBuffer sample: CMSampleBuffer,
                             of type: SCStreamOutputType) {
        guard CMSampleBufferIsValid(sample) else { return }
        switch type {
        case .screen: handleVideoFrame(sample)
        case .audio:  handleSysAudio(sample)
        @unknown default: break
        }
    }

    nonisolated private func handleVideoFrame(_ sample: CMSampleBuffer) {
        guard !writerDidFail() else { return }
        // DEV/TEST: simulate a silent screen-feed death so the stall-watchdog can be verified.
        if simulateStallDeadline > 0, ProcessInfo.processInfo.systemUptime > simulateStallDeadline { return }
        guard let vi = vidInput, vi.isReadyForMoreMediaData else { return }
        let rawPTS = CMSampleBufferGetPresentationTimeStamp(sample)

        let (isPaused, pipRect, outputSize, totalPaused, tZero, isFirst, floating) = locked { s -> (Bool, CGRect, CGSize, CMTime, CMTime, Bool, Bool) in
            if s.isPaused { return (true, s.pipRect, s.outputSize, s.totalPaused, .zero, false, s.cameraFloating) }
            let first = s.tZero == nil
            if first { s.tZero = rawPTS }
            return (false, s.pipRect, s.outputSize, s.totalPaused, s.tZero!, first, s.cameraFloating)
        }
        guard !isPaused else { return }

        if isFirst { writer?.startSession(atSourceTime: .zero) }

        let adjPTS = CMTimeSubtract(CMTimeSubtract(rawPTS, tZero), totalPaused)
        // Drop non-numeric / negative / non-advancing timestamps — a stalling external device
        // can emit these, and a backwards or duplicate PTS makes the writer fail at finalize.
        guard adjPTS.isNumeric, adjPTS >= .zero, adjPTS > lastVideoPTS else { return }

        // While the cam is floating it's recorded as an on-screen window, so suppress the
        // burned-in PiP to avoid a duplicate face cam. Also drop the PiP if the camera has gone
        // stale (no new frame for >1s — e.g. an external cam was unplugged) so we don't burn a
        // frozen face into the video while the watchdog winds down.
        let camStale = (_camera.map { ProcessInfo.processInfo.systemUptime - $0.lastFrameAt > 1 } ?? true)
        let camBuf = (floating || camStale) ? nil : _camera?.latestBuffer()
        if let out = compositor.composite(screenSample: sample,
                                          cameraBuffer: camBuf,
                                          pipRect: pipRect,
                                          outputSize: outputSize),
           adaptor?.append(out, withPresentationTime: adjPTS) == true {
            lastVideoPTS = adjPTS
            videoSampleCount += 1
        }
    }

    nonisolated private func handleSysAudio(_ sample: CMSampleBuffer) {
        guard !writerDidFail() else { return }
        guard let sa = sysAudInput, sa.isReadyForMoreMediaData else { return }
        let rawPTS = CMSampleBufferGetPresentationTimeStamp(sample)

        let (isPaused, totalPaused, tZero, isFirst) = locked { s -> (Bool, CMTime, CMTime, Bool) in
            if s.isPaused { return (true, .zero, .zero, false) }
            let first = s.tZero == nil
            if first { s.tZero = rawPTS }
            return (false, s.totalPaused, s.tZero!, first)
        }
        guard !isPaused else { return }
        if isFirst { writer?.startSession(atSourceTime: .zero) }

        let adjPTS = CMTimeSubtract(CMTimeSubtract(rawPTS, tZero), totalPaused)
        // Must be numeric, non-negative, and not overlap the previous buffer (audio appends
        // fail on overlap; gaps are fine).
        guard adjPTS.isNumeric, adjPTS >= .zero, adjPTS >= lastSysEndPTS else { return }
        if let adj = retimed(sample, to: adjPTS), sa.append(adj) {
            sysAudioSampleCount += 1
            let dur = CMSampleBufferGetDuration(adj)
            lastSysEndPTS = dur.isNumeric ? CMTimeAdd(adjPTS, dur) : adjPTS
            // diagnostics only
            if sysAudioHz == 0 { sysAudioHz = audioSampleRate(sample) }
            if sysFirstPTS == .invalid { sysFirstPTS = adjPTS }
            sysSampleTotal += Int64(CMSampleBufferGetNumSamples(sample))
        }
    }
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate (mic)

extension RecordingSession: AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                    didOutput sample: CMSampleBuffer,
                                    from connection: AVCaptureConnection) {
        lastMicSampleAt = ProcessInfo.processInfo.systemUptime   // device-alive heartbeat
        guard !writerDidFail() else { return }
        guard let ma = micAudInput, ma.isReadyForMoreMediaData else { return }
        let rawPTS = CMSampleBufferGetPresentationTimeStamp(sample)

        let (isPaused, totalPaused, tZero, isFirst) = locked { s -> (Bool, CMTime, CMTime, Bool) in
            if s.isPaused { return (true, .zero, .zero, false) }
            let first = s.tZero == nil
            if first { s.tZero = rawPTS }
            return (false, s.totalPaused, s.tZero!, first)
        }
        guard !isPaused else { return }
        if isFirst { writer?.startSession(atSourceTime: .zero) }

        let adjPTS = CMTimeSubtract(CMTimeSubtract(rawPTS, tZero), totalPaused)
        guard adjPTS.isNumeric, adjPTS >= .zero, adjPTS >= lastMicEndPTS else { return }
        if let adj = retimed(sample, to: adjPTS), ma.append(adj) {
            micSampleCount += 1
            let dur = CMSampleBufferGetDuration(adj)
            lastMicEndPTS = dur.isNumeric ? CMTimeAdd(adjPTS, dur) : adjPTS
            // diagnostics only
            if micAudioHz == 0 { micAudioHz = audioSampleRate(sample) }
            if micFirstPTS == .invalid { micFirstPTS = adjPTS }
            micSampleTotal += Int64(CMSampleBufferGetNumSamples(sample))
        }
    }
}

// MARK: - Helpers

/// Actual sample rate carried by an audio buffer's format description (mSampleRate). Used only
/// for diagnostics — to compare the real capture rate against the tagged 44100.
private func audioSampleRate(_ sample: CMSampleBuffer) -> Double {
    guard let fmt = CMSampleBufferGetFormatDescription(sample),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) else { return 0 }
    return asbd.pointee.mSampleRate
}

/// Shifts an audio buffer onto the recording timeline while PRESERVING its real per-sample
/// timing. The previous version collapsed every buffer to a single timing entry whose
/// duration was the buffer's TOTAL duration — for a multi-sample audio buffer that's
/// malformed timing (the per-entry duration is meant to be one sample's length), and it can
/// make AVAssetWriter fail at finishWriting with CoreMedia timing errors (-12736/-12737),
/// losing the whole recording. Here we copy the original timing array and add a constant
/// offset so the first sample lands at `newPTS`, keeping durations and spacing intact.
private func retimed(_ sample: CMSampleBuffer, to newPTS: CMTime) -> CMSampleBuffer? {
    var count: CMItemCount = 0
    CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)

    if count <= 0 {
        // No timing array — fall back to a single entry with the PER-SAMPLE duration.
        let n = max(1, CMSampleBufferGetNumSamples(sample))
        let total = CMSampleBufferGetDuration(sample)
        let per = (total.isValid && total.value > 0)
            ? CMTimeMultiplyByRatio(total, multiplier: 1, divisor: Int32(n))
            : CMTime.invalid
        var timing = CMSampleTimingInfo(duration: per, presentationTimeStamp: newPTS, decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &out)
        return out
    }

    var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
    CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timings, entriesNeededOut: nil)
    let originalFirst = timings.first?.presentationTimeStamp ?? CMSampleBufferGetPresentationTimeStamp(sample)
    let delta = CMTimeSubtract(newPTS, originalFirst)
    for i in timings.indices {
        if timings[i].presentationTimeStamp.isValid {
            timings[i].presentationTimeStamp = CMTimeAdd(timings[i].presentationTimeStamp, delta)
        }
        timings[i].decodeTimeStamp = .invalid
    }
    var out: CMSampleBuffer?
    CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample,
        sampleTimingEntryCount: count, sampleTimingArray: &timings, sampleBufferOut: &out)
    return out
}

enum CCError: LocalizedError {
    case noDisplay
    case writerSetupFailed
    var errorDescription: String? {
        switch self {
        case .noDisplay:         return "No display found to record."
        case .writerSetupFailed: return "Could not start the recording file. Please try again."
        }
    }
}
