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
    private static let isTestBuild = true // Set to false for production

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
    }

    private nonisolated func locked<T>(_ work: (inout CS) -> T) -> T {
        captureLock.lock(); defer { captureLock.unlock() }
        return work(&cs)
    }

    // MARK: Infrastructure (main actor only)
    private var stream:     SCStream?
    private var micSession: AVCaptureSession?
    private var outputURL:  URL?

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

    func start(config: RecordingConfig, camera: CameraManager, isLicensed: Bool) async throws {
        guard !isRunning else { return }

        _camera    = camera
        outputURL  = config.outputURL

        // Free tier: 120s limit (disabled for test builds)
        let effectivelyLicensed = isLicensed || Self.isTestBuild
        if !effectivelyLicensed {
            startFreeRecordingTimer()
        } else {
            recordingTimeRemaining = nil
        }
        cs = CS()   // reset state
        locked {
            $0.pipRect    = config.pipNormalizedRect
            $0.outputSize = config.videoSize
        }

        try setupWriter(config: config)

        // On macOS 15+, system handles screen selection picker — skip TCC checks
        let display: SCDisplay
        if #available(macOS 15.0, *) {
            NSLog("DEBUG: macOS 15+ — using default primary display, system will show picker if needed")
            let content = try await SCShareableContent.current
            guard let d = content.displays.first else {
                throw CCError.noDisplay
            }
            display = d
        } else {
            // macOS 14 and earlier: get shareable content (may trigger TCC dialog)
            NSLog("DEBUG: macOS 14 or earlier — fetching SCShareableContent with TCC check...")
            let content: SCShareableContent
            do {
                content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                NSLog("DEBUG: SCShareableContent succeeded. Displays: \(content.displays.count)")
            } catch {
                let nsError = error as NSError
                NSLog("ERROR: SCShareableContent failed - \(nsError.localizedDescription)")
                throw nsError
            }
            guard let d = content.displays.first else {
                NSLog("ERROR: No displays found")
                throw CCError.noDisplay
            }
            display = d
        }
        NSLog("DEBUG: Using display: \(display)")

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

        setupMicCapture(deviceID: config.selectedMicID)

        NSLog("DEBUG: Starting AVAssetWriter...")
        writer?.startWriting()

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

        isRunning = true
        isPaused  = false
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
        recordingTimeRemaining = 120
        freeTimerTask = Task { @MainActor in
            for second in stride(from: 120, through: 1, by: -1) {
                if Task.isCancelled { break }
                recordingTimeRemaining = second
                try? await Task.sleep(for: .seconds(1))
            }
            // Time's up — auto stop
            if isRunning {
                _ = await stop()
                errorMessage = "Free tier limited to 120 seconds. Upgrade to record longer."
            }
        }
    }

    // MARK: - Stop

    func stop() async -> URL? {
        guard isRunning else { return nil }
        isRunning = false; isPaused = false
        freeTimerTask?.cancel()
        recordingTimeRemaining = nil
        try? await stream?.stopCapture()
        stream = nil
        micSession?.stopRunning()
        micSession = nil

        return await withCheckedContinuation { cont in
            writer?.finishWriting { [weak self] in
                cont.resume(returning: self?.outputURL)
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

    // MARK: - Private setup

    private func setupWriter(config: RecordingConfig) throws {
        let w = try AVAssetWriter(outputURL: config.outputURL, fileType: .mp4)

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

        let audioSettings: [String: Any] = [
            AVFormatIDKey:         kAudioFormatMPEG4AAC,
            AVSampleRateKey:       44100,
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
        Task { @MainActor [weak self] in
            self?.errorMessage = error.localizedDescription
            self?.isRunning = false
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
        guard let vi = vidInput, vi.isReadyForMoreMediaData else { return }
        let rawPTS = CMSampleBufferGetPresentationTimeStamp(sample)

        let (isPaused, pipRect, outputSize, totalPaused, tZero, isFirst) = locked { s -> (Bool, CGRect, CGSize, CMTime, CMTime, Bool) in
            if s.isPaused { return (true, s.pipRect, s.outputSize, s.totalPaused, .zero, false) }
            let first = s.tZero == nil
            if first { s.tZero = rawPTS }
            return (false, s.pipRect, s.outputSize, s.totalPaused, s.tZero!, first)
        }
        guard !isPaused else { return }

        if isFirst { writer?.startSession(atSourceTime: .zero) }

        let adjPTS = CMTimeSubtract(CMTimeSubtract(rawPTS, tZero), totalPaused)
        guard CMTIME_IS_VALID(adjPTS), adjPTS >= .zero else { return }

        let camBuf = _camera?.latestBuffer()
        if let out = compositor.composite(screenSample: sample,
                                          cameraBuffer: camBuf,
                                          pipRect: pipRect,
                                          outputSize: outputSize) {
            adaptor?.append(out, withPresentationTime: adjPTS)
        }
    }

    nonisolated private func handleSysAudio(_ sample: CMSampleBuffer) {
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
        guard CMTIME_IS_VALID(adjPTS), adjPTS >= .zero else { return }
        if let adj = retimed(sample, to: adjPTS) { sa.append(adj) }
    }
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate (mic)

extension RecordingSession: AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                    didOutput sample: CMSampleBuffer,
                                    from connection: AVCaptureConnection) {
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
        guard CMTIME_IS_VALID(adjPTS), adjPTS >= .zero else { return }
        if let adj = retimed(sample, to: adjPTS) { ma.append(adj) }
    }
}

// MARK: - Helpers

private func retimed(_ sample: CMSampleBuffer, to newPTS: CMTime) -> CMSampleBuffer? {
    var timing = CMSampleTimingInfo(
        duration: CMSampleBufferGetDuration(sample),
        presentationTimeStamp: newPTS,
        decodeTimeStamp: .invalid
    )
    var out: CMSampleBuffer?
    CMSampleBufferCreateCopyWithNewTiming(
        allocator: nil, sampleBuffer: sample,
        sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleBufferOut: &out)
    return out
}

enum CCError: LocalizedError {
    case noDisplay
    var errorDescription: String? {
        switch self { case .noDisplay: return "No display found to record." }
    }
}
