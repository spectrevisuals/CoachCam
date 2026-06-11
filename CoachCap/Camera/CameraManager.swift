import AVFoundation
import CoreImage
import Combine

/// Manages face-cam capture. Publishes `currentFrame` for SwiftUI preview.
/// `latestBuffer()` is nonisolated and lock-protected so FrameCompositor
/// can call it safely from the encode queue.
@MainActor
final class CameraManager: NSObject, ObservableObject {
    @Published var currentFrame: CIImage?
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

    override init() {
        super.init()
        NSLog("DEBUG CameraManager: init called")
        enumerateDevices()
    }

    func enumerateDevices() {
        // Try multiple device type combinations to catch all cameras
        var cameras: [AVCaptureDevice] = []

        // Attempt 1: Built-in wide angle, front position
        cameras = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .front
        ).devices
        NSLog("DEBUG CameraManager: Front built-in: \(cameras.count)")

        if cameras.isEmpty {
            // Attempt 2: Any video device, unspecified position
            cameras = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified
            ).devices
            NSLog("DEBUG CameraManager: Unspecified position: \(cameras.count)")
        }

        if cameras.isEmpty {
            // Attempt 3: All video devices (macOS 14+)
            cameras = AVCaptureDevice.devices(for: .video)
            NSLog("DEBUG CameraManager: All video devices: \(cameras.count)")
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
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        NSLog("DEBUG CameraManager: Authorization status = \(status.rawValue)")

        switch status {
        case .notDetermined:
            NSLog("DEBUG CameraManager: Permission not determined, requesting...")
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                NSLog("DEBUG CameraManager: Permission request result: \(granted)")
                if granted { DispatchQueue.main.async { self?.startCapture(cameraID: cameraID) } }
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
        currentFrame = nil
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

        // Dispatch to MainActor synchronously BEFORE buffer is released
        let image = CIImage(cvPixelBuffer: pb)
        DispatchQueue.main.async { [weak self] in
            NSLog("DEBUG CameraManager: In main queue dispatch")
            guard let self else {
                NSLog("DEBUG CameraManager: Self is nil in dispatch")
                return
            }
            var transformedImage = image
            if self.mirrorEnabled {
                transformedImage = transformedImage.transformed(
                    by: CGAffineTransform(scaleX: -1, y: 1)
                        .translatedBy(x: -transformedImage.extent.width, y: 0)
                )
            }
            self.currentFrame = transformedImage
            NSLog("📸 SET on \(ObjectIdentifier(self)) — frame \(transformedImage.extent.size)")
        }
    }
}
