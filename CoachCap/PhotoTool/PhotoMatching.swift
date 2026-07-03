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

    /// Upper bound on how far apart an SD/HD twin can hash. A real twin is far closer than this
    /// (measured ≤10), but a plain distance threshold can't be used alone: one client's *twin*
    /// can sit at distance 10 while another client's genuinely *different* poses also sit at 10.
    /// So this is only a safety cap on top of the real discriminators below.
    static let dupHashCap = 25

    /// Removes WhatsApp's HD/standard duplicate pairs, keeping the larger (HD) copy. WhatsApp
    /// sends the HD photo as a second message, so each pose arrives as an SD file + an HD file.
    ///
    /// Two photos are the SAME shot (a twin) when ALL of these hold — which reliably separates a
    /// twin from two similar-but-different physique poses:
    ///   1. they are each other's **nearest** neighbour by perceptual hash (a twin is always the
    ///      closest match; a different pose always has its own twin nearer),
    ///   2. their hashes are within `dupHashCap` (safety net when a photo has no real twin),
    ///   3. their file sizes differ notably (SD vs HD — different quality tiers; two same-tier
    ///      poses have near-equal sizes), and
    ///   4. they were sent within 60s of each other (SD + HD go out together; guards against
    ///      collapsing lookalikes from different check-ins when a date range is deduped).
    nonisolated static func dedupHDDuplicates(_ items: [WhatsAppMediaItem]) -> [WhatsAppMediaItem] {
        let n = items.count
        guard n > 1 else { return items }
        let hashes = items.map { perceptualHash($0.url) }

        func dist(_ i: Int, _ j: Int) -> Int? {
            guard let a = hashes[i], let b = hashes[j] else { return nil }
            return hammingDistance(a, b)
        }
        // Nearest neighbour (by hash) of each item.
        var nearest = [Int](repeating: -1, count: n)
        for i in 0..<n where hashes[i] != nil {
            var best = Int.max
            for j in 0..<n where j != i {
                if let d = dist(i, j), d < best { best = d; nearest[i] = j }
            }
        }

        var dropped = Set<Int>()
        for i in 0..<n {
            let j = nearest[i]
            guard j >= 0, !dropped.contains(i), !dropped.contains(j) else { continue }
            guard nearest[j] == i else { continue }                    // 1. mutual nearest
            guard let d = dist(i, j), d <= dupHashCap else { continue } // 2. within safety cap
            let a = items[i].fileSize, b = items[j].fileSize           // 3. SD vs HD sizes
            guard min(a, b) > 0, Double(max(a, b)) / Double(min(a, b)) >= 1.5 else { continue }
            guard abs(items[i].date.timeIntervalSince(items[j].date)) <= 60 else { continue }  // 4. same send
            dropped.insert(a >= b ? j : i)                              // drop the smaller (SD)
        }
        return items.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)
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
        // Primary decode path.
        var cg = CGImageSourceCreateWithURL(url as CFURL, nil)
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        // Fallback for images CGImageSource can't decode directly (some HEIC / odd encodings):
        // let NSImage decode and render to a CGImage. Without this, an unhashable HD/standard
        // pair returns nil for both and BYPASSES dedup — which is one way photos show twice.
        if cg == nil {
            cg = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        guard let cg else { return nil }

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
