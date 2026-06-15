import AVFoundation
import CoreImage
import Combine
import AppKit

/// Manages face-cam capture. Publishes `currentFrame` for SwiftUI preview.
/// `latestBuffer()` is nonisolated and lock-protected so FrameCompositor
/// can call it safely from the encode queue.
@MainActor
final class CameraManager: NSObject, ObservableObject {
    /// Rendered preview frame. We publish a CGImage (not a CIImage-backed NSImage), because
    /// SwiftUI renders CIImage-backed NSImages unreliably — that was the cause of the blank
    /// grey preview even while valid frames were arriving.
    @Published var previewImage: CGImage?

    /// Shared GPU-backed context for rendering preview frames.
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    @Published var availableCameras: [AVCaptureDevice] = []
    @Published var availableMics: [AVCaptureDevice] = []
    @Published var mirrorEnabled: Bool = true
    @Published var activeSession: AVCaptureSession?

    private var captureSession: AVCaptureSession? {
        didSet {
            activeSession = captureSession
        }
    }
    private let sampleQueue = DispatchQueue(label: "com.coachcap.camera.output", qos: .userInteractive)

    // nonisolated(unsafe): written on capture queue, read on encode queue.
    // Thread safety is provided by bufferLock.
    nonisolated(unsafe) private var _latestBuffer: CVPixelBuffer?
    private let bufferLock = NSLock()

    private var activeObserver: NSObjectProtocol?
    private var lastCameraID: String?

    override init() {
        super.init()
        NSLog("DEBUG CameraManager: init called")
        refreshDevicesRequestingAccessIfNeeded()
        // Re-scan whenever the app returns to the foreground, so granting the camera
        // in System Settings (or anywhere) takes effect immediately — no relaunch.
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshOnActivation() }
        }
    }

    /// On returning to the app, re-scan devices and — crucially — start the camera if
    /// permission has just been granted (e.g. enabled in System Settings) and we aren't
    /// already capturing. This is what makes a freshly-granted camera appear without a relaunch.
    private func refreshOnActivation() {
        enumerateDevices()
        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized, captureSession == nil {
            startCapture(cameraID: lastCameraID)
        }
    }

    deinit {
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
    }

    /// Shows the camera permission prompt if the user hasn't answered yet, then (re)builds
    /// the device list once the system responds — so the camera appears the moment access
    /// is granted, instead of staying greyed out until the app is relaunched.
    func refreshDevicesRequestingAccessIfNeeded() {
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
                Task { @MainActor in self?.enumerateDevices() }
            }
        } else {
            enumerateDevices()
        }
    }

    func enumerateDevices() {
        // Enumerate ALL camera types in one pass — previously this used a fallback chain
        // that stopped at the built-in camera, which hid connected external webcams.
        var cameraTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external]
        cameraTypes.append(.continuityCamera)   // iPhone / Continuity Camera
        cameraTypes.append(.deskViewCamera)

        var cameras = AVCaptureDevice.DiscoverySession(
            deviceTypes: cameraTypes, mediaType: .video, position: .unspecified
        ).devices
        // Belt-and-braces: if the discovery session somehow returns nothing, fall back to
        // the broad query so we never end up with an empty list when a camera exists.
        if cameras.isEmpty {
            cameras = AVCaptureDevice.devices(for: .video)
        }

        availableCameras = cameras
        NSLog("DEBUG CameraManager: Final camera list: \(availableCameras.map { $0.localizedName }.joined(separator: ", "))")

        // Mics
        let audioDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .external], mediaType: .audio, position: .unspecified
        ).devices
        availableMics = audioDevices
        NSLog("DEBUG CameraManager: Available mics: \(availableMics.map { $0.localizedName }.joined(separator: ", "))")
    }

    func requestCameraAccess(then start: @escaping () -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted { DispatchQueue.main.async { start() } }
            }
        default:
            break
        }
    }

    func startCapture(cameraID: String? = nil) {
        NSLog("DEBUG CameraManager: startCapture called")
        lastCameraID = cameraID
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        NSLog("DEBUG CameraManager: Authorization status = \(status.rawValue)")

        switch status {
        case .notDetermined:
            NSLog("DEBUG CameraManager: Permission not determined, requesting...")
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                NSLog("DEBUG CameraManager: Permission request result: \(granted)")
                if granted {
                    DispatchQueue.main.async {
                        self?.enumerateDevices()          // refresh the now-available device list
                        self?.startCapture(cameraID: cameraID)
                    }
                }
            }
            return
        case .denied:
            NSLog("DEBUG CameraManager: Camera permission DENIED")
            return
        case .restricted:
            NSLog("DEBUG CameraManager: Camera permission RESTRICTED")
            return
        default:
            NSLog("DEBUG CameraManager: Permission status authorized, proceeding")
        }

        stopCapture()

        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720

        let camera = resolveCamera(id: cameraID)
        NSLog("DEBUG CameraManager: Resolved camera: \(camera?.localizedName ?? "nil")")

        if let cam = camera {
            do {
                let input = try AVCaptureDeviceInput(device: cam)
                if session.canAddInput(input) {
                    session.addInput(input)
                    NSLog("DEBUG CameraManager: Added camera input")
                } else {
                    NSLog("DEBUG CameraManager: Cannot add camera input (canAddInput=false)")
                }
            } catch {
                NSLog("DEBUG CameraManager: Failed to create camera input: \(error)")
            }
        } else {
            NSLog("DEBUG CameraManager: No camera device resolved")
        }

        let videoOut = AVCaptureVideoDataOutput()
        videoOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOut.setSampleBufferDelegate(self, queue: sampleQueue)
        videoOut.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoOut) {
            session.addOutput(videoOut)
            NSLog("DEBUG CameraManager: Added video output")
        } else {
            NSLog("DEBUG CameraManager: Cannot add video output")
        }

        if let cam = camera, cam.position == .front,
           let conn = videoOut.connection(with: .video) {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = true
        }

        session.commitConfiguration()
        captureSession = session
        NSLog("DEBUG CameraManager: Session configured with \(session.inputs.count) inputs, \(session.outputs.count) outputs")
        sampleQueue.async {
            session.startRunning()
            NSLog("DEBUG CameraManager: Session.startRunning() called, isRunning: \(session.isRunning)")
        }
    }

    func stopCapture() {
        captureSession?.stopRunning()
        captureSession = nil
        bufferLock.lock(); _latestBuffer = nil; bufferLock.unlock()
        previewImage = nil
    }

    /// Called by FrameCompositor from the encode queue — must be nonisolated.
    nonisolated func latestBuffer() -> CVPixelBuffer? {
        bufferLock.lock(); defer { bufferLock.unlock() }
        return _latestBuffer
    }

    private func resolveCamera(id: String?) -> AVCaptureDevice? {
        if let id, let dev = AVCaptureDevice(uniqueID: id) { return dev }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video)
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        NSLog("DEBUG CameraManager: captureOutput delegate called")
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            NSLog("DEBUG CameraManager: No pixel buffer in sample")
            return
        }
        bufferLock.lock(); _latestBuffer = pb; bufferLock.unlock()

        // Retain the buffer's image now, then hand the rendered CGImage to the main actor.
        let image = CIImage(cvPixelBuffer: pb)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var output = image
            if self.mirrorEnabled {
                output = output.transformed(
                    by: CGAffineTransform(scaleX: -1, y: 1)
                        .translatedBy(x: -output.extent.width, y: 0)
                )
            }
            // Downscale for the preview (it's small) to keep the per-frame render cheap.
            let target: CGFloat = 540
            if output.extent.height > target {
                let s = target / output.extent.height
                output = output.transformed(by: CGAffineTransform(scaleX: s, y: s))
            }
            if let cg = Self.ciContext.createCGImage(output, from: output.extent) {
                self.previewImage = cg
            }
        }
    }
}
