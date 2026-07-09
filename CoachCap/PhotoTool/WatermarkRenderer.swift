import AppKit
import CoreText
import SwiftUI

/// Displays an image with the free-tier watermark composited in (for free users) via the
/// SAME `WatermarkRenderer.apply` used at export — so every before/after view (manual,
/// compare, browse) shows exactly what the client receives, and screenshots can't bypass it.
/// The watermarked copy is cached and only recomputed when the image or licence changes.
struct WatermarkedImage: View {
    let image: NSImage
    var contentMode: ContentMode = .fit

    @ObservedObject private var license = LicenseManager.shared
    @State private var rendered: NSImage?

    var body: some View {
        Image(nsImage: rendered ?? image)
            .resizable()
            .aspectRatio(contentMode: contentMode)
            .onAppear { update() }
            .onChange(of: image) { _, _ in update() }
            .onChange(of: license.isUnlocked) { _, _ in update() }
    }

    private func update() {
        rendered = image   // watermark removed — full-access trial/paid model, no free tier
    }
}

/// The SINGLE place the free-tier watermark is drawn. Both the in-app comparison preview
/// AND the exported JPEG call `apply(to:)`, so what the coach sees matches what the client
/// receives and it can't be bypassed by screenshotting the preview. It composites diagonal
/// tiled "CoachCam" text onto the real pixels (thread-safe CGContext, not a SwiftUI overlay).
enum WatermarkRenderer {

    static func apply(to image: NSImage) -> NSImage {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cg.width > 0, cg.height > 0 else { return image }

        let w = cg.width, h = cg.height
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }

        // Base image
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Watermark text (scales with image size)
        let fontSize = max(14, CGFloat(min(w, h)) * FreeTier.watermarkFontFraction)
        let nsFont = NSFont(name: "Quicksand", size: fontSize) ?? NSFont.boldSystemFont(ofSize: fontSize)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: nsFont,
            .foregroundColor: NSColor.white.withAlphaComponent(FreeTier.watermarkOpacity)
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: FreeTier.watermarkText, attributes: attrs))
        let bounds = CTLineGetBoundsWithOptions(line, [])

        ctx.saveGState()
        ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
        ctx.rotate(by: FreeTier.watermarkAngleDegrees * .pi / 180)

        let stepX = bounds.width  * 1.8
        let stepY = bounds.height * 3.5
        let reach = CGFloat(max(w, h))            // covers the canvas after rotation
        var y = -reach
        var row = 0
        while y < reach {
            let offset = (row % 2 == 0) ? 0 : stepX / 2   // brick-stagger the rows
            var x = -reach + offset
            while x < reach {
                ctx.textPosition = CGPoint(x: x, y: y)
                CTLineDraw(line, ctx)
                x += stepX
            }
            y += stepY
            row += 1
        }
        ctx.restoreGState()

        guard let out = ctx.makeImage() else { return image }
        return NSImage(cgImage: out, size: image.size)
    }
}
