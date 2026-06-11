import SwiftUI
import AppKit
import Combine

struct CameraPreviewView: View {
    @ObservedObject var camera: CameraManager
    @State private var frameUpdateTrigger = UUID()

    var body: some View {
        ZStack {
            if let frame = camera.currentFrame {
                Image(nsImage: NSImage(ciImage: frame))
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
            } else {
                Color.black
            }
        }
        .onAppear {
            NSLog("👀 VIEW observing \(ObjectIdentifier(camera)) — frame is \(camera.currentFrame != nil ? "present" : "nil")")
        }
    }
}

private extension NSImage {
    convenience init(ciImage: CIImage) {
        let rep = NSCIImageRep(ciImage: ciImage)
        self.init(size: rep.size)
        addRepresentation(rep)
    }
}
