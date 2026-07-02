import XCTest
import AppKit
import CoreGraphics

// Compiles PhotoMatching.swift directly into this test bundle (see project.yml), so no app
// host / @testable import is needed — keeps the tests fast and headless.
final class PhotoMatchingTests: XCTestCase {

    func testHammingDistance() {
        XCTAssertEqual(PhotoMatching.hammingDistance([0, 0, 0, 0], [0, 0, 0, 0]), 0)
        XCTAssertEqual(PhotoMatching.hammingDistance([0b1011, 0, 0, 0], [0, 0, 0, 0]), 3)
        XCTAssertEqual(PhotoMatching.hammingDistance([UInt64.max, 0, 0, 0], [0, 0, 0, 0]), 64)
    }

    /// The recurring "photos shown twice" regression: an HD + standard pair (same image at a
    /// different size/file) must collapse to ONE, keeping the larger copy; a genuinely
    /// different photo must survive.
    func testDedupCollapsesHDPairAndKeepsDistinct() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("coachcam-dedup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // std + hd = the same image (dark→light gradient) at two sizes → perceptual twins.
        let std = try writeGradient(reversed: false, size: 400,  to: dir.appendingPathComponent("std.jpg"))
        let hd  = try writeGradient(reversed: false, size: 1400, to: dir.appendingPathComponent("hd.jpg"))
        // other = reversed gradient → perceptually distinct.
        let other = try writeGradient(reversed: true, size: 400, to: dir.appendingPathComponent("other.jpg"))

        func item(_ url: URL) -> WhatsAppMediaItem {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return WhatsAppMediaItem(url: url, date: Date(), fileSize: size)
        }

        let result = PhotoMatching.dedupHDDuplicates([item(std), item(hd), item(other)])

        XCTAssertEqual(result.count, 2, "HD+standard pair should collapse to one; distinct photo kept")
        XCTAssertTrue(result.contains { $0.url == hd },    "should keep the larger HD copy, not the standard one")
        XCTAssertTrue(result.contains { $0.url == other }, "a genuinely different photo must survive dedup")
    }

    /// Two identical images must be twins (distance 0); opposite gradients must be far apart —
    /// this is what keeps the dedup threshold meaningful.
    func testPerceptualHashTwinsVsDistinct() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("coachcam-hash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = try writeGradient(reversed: false, size: 500, to: dir.appendingPathComponent("a.jpg"))
        let b = try writeGradient(reversed: false, size: 900, to: dir.appendingPathComponent("b.jpg"))
        let c = try writeGradient(reversed: true,  size: 500, to: dir.appendingPathComponent("c.jpg"))

        let ha = try XCTUnwrap(PhotoMatching.perceptualHash(a))
        let hb = try XCTUnwrap(PhotoMatching.perceptualHash(b))
        let hc = try XCTUnwrap(PhotoMatching.perceptualHash(c))

        XCTAssertLessThanOrEqual(PhotoMatching.hammingDistance(ha, hb), 7, "same image at two sizes should be twins")
        XCTAssertGreaterThan(PhotoMatching.hammingDistance(ha, hc), 7, "opposite images should be distinct")
    }

    // Writes a horizontal grayscale gradient JPEG; `reversed` flips light/dark so the two
    // gradients are perceptually opposite.
    private func writeGradient(reversed: Bool, size: Int, to url: URL) throws -> URL {
        let w = size, h = size
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue))
        for x in 0..<w {
            let t = CGFloat(x) / CGFloat(max(1, w - 1))
            ctx.setFillColor(CGColor(gray: reversed ? (1 - t) : t, alpha: 1))
            ctx.fill(CGRect(x: x, y: 0, width: 1, height: h))
        }
        let cg  = try XCTUnwrap(ctx.makeImage())
        let rep = NSBitmapImageRep(cgImage: cg)
        let data = try XCTUnwrap(rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]))
        try data.write(to: url)
        return url
    }
}
