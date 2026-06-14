import SwiftUI
import AppKit
import Combine

struct CameraPreviewView: View {
    @ObservedObject var camera: CameraManager
    @State private var frameUpdateTrigger = UUID()

    var body: some View {
        ZStack {
            if let frame = camera.previewImage {
                Image(decorative: frame, scale: 1, orientation: .up)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
            } else {
                Color.black
            }
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
