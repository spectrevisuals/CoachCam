import CoreImage
import CoreMedia
import CoreVideo
import AVFoundation

/// Composites a camera pixel buffer as a rounded PiP onto a screen frame.
/// All methods called from the encode queue (never main thread).
final class FrameCompositor {
    private let context = CIContext(options: [.useSoftwareRenderer: false,
                                               .cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private var poolSize: CGSize = .zero

    var mirrorCamera = false

    func composite(
        screenSample: CMSampleBuffer,
        cameraBuffer: CVPixelBuffer?,
        pipRect: CGRect,        // normalised 0-1, top-left origin
        outputSize: CGSize
    ) -> CVPixelBuffer? {
        guard let screenPB = CMSampleBufferGetImageBuffer(screenSample) else { return nil }
        if poolSize != outputSize { rebuildPool(size: outputSize) }
        guard let pool else { return nil }

        var outBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuffer) == kCVReturnSuccess,
              let out = outBuffer else { return nil }

        // Build CI image from screen, scaling if the capture size differs
        let srcW = CGFloat(CVPixelBufferGetWidth(screenPB))
        let srcH = CGFloat(CVPixelBufferGetHeight(screenPB))
        var screenCI = CIImage(cvPixelBuffer: screenPB)
        if srcW != outputSize.width || srcH != outputSize.height {
            screenCI = screenCI.transformed(by: .init(scaleX: outputSize.width / srcW,
                                                       y: outputSize.height / srcH))
        }

        var composite = screenCI

        if let cam = cameraBuffer {
            var camCI = CIImage(cvPixelBuffer: cam)
            if mirrorCamera {
                camCI = camCI.transformed(
                    by: CGAffineTransform(scaleX: -1, y: 1)
                        .translatedBy(x: -camCI.extent.width, y: 0)
                )
            }
            composite = overlayPiP(base: screenCI,
                                   camera: camCI,
                                   pipRect: pipRect,
                                   canvasSize: outputSize)
        }

        context.render(composite,
                       to: out,
                       bounds: CGRect(origin: .zero, size: outputSize),
                       colorSpace: CGColorSpaceCreateDeviceRGB())
        return out
    }

    // MARK: - Private

    private func overlayPiP(base: CIImage,
                             camera: CIImage,
                             pipRect: CGRect,
                             canvasSize: CGSize) -> CIImage {
        let pw = pipRect.width  * canvasSize.width
        let ph = pipRect.height * canvasSize.height
        let px = pipRect.origin.x * canvasSize.width
        let py = pipRect.origin.y * canvasSize.height   // top-left origin

        // Scale camera to fill pip box (aspect-fill + centre-crop)
        let camW = camera.extent.width
        let camH = camera.extent.height
        let scale = max(pw / camW, ph / camH)
        var scaled = camera.transformed(by: .init(scaleX: scale, y: scale))

        let cropX = (scaled.extent.width  - pw) / 2
        let cropY = (scaled.extent.height - ph) / 2
        scaled = scaled.cropped(to: CGRect(x: scaled.extent.minX + cropX,
                                           y: scaled.extent.minY + cropY,
                                           width: pw, height: ph))

        // CIImage Y-axis is bottom-up; screen py is top-down → flip
        let ciY = canvasSize.height - py - ph
        let positioned = scaled.transformed(
            by: .init(translationX: px - scaled.extent.minX,
                      y: ciY - scaled.extent.minY))

        // Round corners using traditional CIFilter API
        let pipCIRect = CGRect(x: px, y: ciY, width: pw, height: ph)
        let radius = pw * 0.08
        let rounded = roundedMask(image: positioned, rect: pipCIRect, radius: radius)

        return rounded.composited(over: base)
    }

    private func roundedMask(image: CIImage, rect: CGRect, radius: CGFloat) -> CIImage {
        guard let maskFilter = CIFilter(name: "CIRoundedRectangleGenerator") else { return image }
        maskFilter.setValue(CIVector(cgRect: rect), forKey: "inputExtent")
        maskFilter.setValue(radius as NSNumber,      forKey: "inputRadius")
        maskFilter.setValue(CIColor.white,            forKey: "inputColor")
        guard let mask = maskFilter.outputImage else { return image }

        return image.applyingFilter("CIBlendWithMask", parameters: [
            "inputMaskImage":       mask,
            "inputBackgroundImage": CIImage.empty(),
        ])
    }

    private func rebuildPool(size: CGSize) {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey  as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
        pool = p
        poolSize = size
    }
}
