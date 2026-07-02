import Foundation
import AppKit
import CoreGraphics
import ImageIO

// MARK: - Data

/// A WhatsApp media item (photo). Pure data, kept here (dependency-free) alongside the matching
/// logic so both can be unit-tested without the DB/UI layer.
struct WhatsAppMediaItem: Identifiable {
    let id    = UUID()
    let url:   URL
    let date:  Date
    var fileSize: Int = 0
    var thumb: NSImage?
}

// MARK: - Perceptual-hash photo matching

/// Collapses WhatsApp's HD/standard duplicate photo pairs, and builds thumbnails. Extracted
/// into its own dependency-free file so `Tests/PhotoMatchingTests` can guard the recurring
/// "photos shown twice" regression directly. `WhatsAppMediaLoader` forwards to these.
enum PhotoMatching {

    /// Removes WhatsApp's HD/standard duplicate pairs. WhatsApp sends an HD photo as a
    /// second message holding a higher-res copy of the standard one, so the same image
    /// arrives twice with different files. We match by a 256-bit perceptual hash and keep
    /// the larger (HD) copy. Threshold 7 sits safely between true twins (≤3) and distinct
    /// physique photos of the same client (≥11) measured on real check-in data.
    nonisolated static func dedupHDDuplicates(_ items: [WhatsAppMediaItem]) -> [WhatsAppMediaItem] {
        struct Kept { var item: WhatsAppMediaItem; let hash: [UInt64]? }
        var kept: [Kept] = []
        for item in items {
            let hash = perceptualHash(item.url)
            if let hash,
               let idx = kept.firstIndex(where: { $0.hash != nil && hammingDistance($0.hash!, hash) <= 7 }) {
                // Duplicate of an already-kept photo — keep whichever file is larger (HD).
                if item.fileSize > kept[idx].item.fileSize {
                    kept[idx] = Kept(item: item, hash: hash)
                }
            } else {
                kept.append(Kept(item: item, hash: hash))
            }
        }
        return kept.map { $0.item }
    }

    /// 256-bit dHash: downscale to a 17×16 luma grid and record, per row, whether each
    /// pixel is brighter than its right-hand neighbour (16×16 = 256 comparisons).
    ///
    /// We decode the full image and let CoreGraphics do a single high-quality downsample
    /// straight to the grid. Going via a small intermediate thumbnail (or `.low`
    /// interpolation) resamples the standard and HD copies inconsistently and pushes true
    /// twins past the match threshold — measured on real check-in data, the full/high path
    /// keeps twins ≤3 while distinct photos stay ≥11.
    // Hashing decodes the full image, so cache by path: the date list and the per-date
    // photo load both hash the same files, and a file's pixels never change.
    private static let hashCacheLock = NSLock()
    nonisolated(unsafe) private static var hashCache: [String: [UInt64]?] = [:]

    nonisolated static func perceptualHash(_ url: URL) -> [UInt64]? {
        let key = url.path
        hashCacheLock.lock()
        if let cached = hashCache[key] { hashCacheLock.unlock(); return cached }
        hashCacheLock.unlock()

        let result = computePerceptualHash(url)

        hashCacheLock.lock()
        hashCache[key] = result
        hashCacheLock.unlock()
        return result
    }

    nonisolated static func computePerceptualHash(_ url: URL) -> [UInt64]? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg  = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return nil }

        let w = 17, h = 16
        var pixels = [UInt8](repeating: 0, count: w * h)
        let gray = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: gray,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var bits = [UInt64](repeating: 0, count: 4) // 256 bits
        var k = 0
        for y in 0..<h {
            for x in 0..<(w - 1) {
                if pixels[y * w + x] > pixels[y * w + x + 1] {
                    bits[k >> 6] |= (UInt64(1) << UInt64(k & 63))
                }
                k += 1
            }
        }
        return bits
    }

    nonisolated static func hammingDistance(_ a: [UInt64], _ b: [UInt64]) -> Int {
        var d = 0
        for i in 0..<min(a.count, b.count) { d += (a[i] ^ b[i]).nonzeroBitCount }
        return d
    }

    nonisolated static func makeThumbnail(_ url: URL, maxPx: CGFloat = 200) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPx,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
