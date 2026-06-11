import SwiftUI
import AVFoundation

struct CameraPreviewLayer: NSViewRepresentable {
    let session: AVCaptureSession?

    class PreviewView: NSView {
        var previewLayer: AVCaptureVideoPreviewLayer?

        override var frame: CGRect {
            didSet {
                previewLayer?.frame = bounds
                NSLog("DEBUG PreviewView: Frame changed to \(frame), bounds: \(bounds)")
            }
        }

        override var bounds: CGRect {
            didSet {
                previewLayer?.frame = bounds
                NSLog("DEBUG PreviewView: Bounds changed to \(bounds)")
            }
        }

        override func layout() {
            super.layout()
            previewLayer?.frame = bounds
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = PreviewView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.autoresizingMask = [.width, .height]
        NSLog("DEBUG CameraPreviewLayer: Created PreviewView")
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let previewView = nsView as? PreviewView else {
            NSLog("DEBUG CameraPreviewLayer: Not a PreviewView")
            return
        }

        // Remove old preview layer if exists
        previewView.layer?.sublayers?.removeAll { $0 is AVCaptureVideoPreviewLayer }

        if let session = session {
            NSLog("DEBUG CameraPreviewLayer: Session available, running: \(session.isRunning)")
            NSLog("DEBUG CameraPreviewLayer: View frame: \(previewView.frame), bounds: \(previewView.bounds)")

            let previewLayer = AVCaptureVideoPreviewLayer(session: session)
            previewLayer.videoGravity = .resizeAspectFill
            previewLayer.frame = previewView.bounds
            previewView.layer?.addSublayer(previewLayer)
            previewView.previewLayer = previewLayer

            NSLog("DEBUG CameraPreviewLayer: Preview layer added")
        } else {
            NSLog("DEBUG CameraPreviewLayer: Session is nil")
        }
    }
}
