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

    /// An SD + HD pair (same image, small file + big file, same send) collapses to the HD; a
    /// genuinely different photo survives. This is the "photos shown twice" bug.
    func testDedupCollapsesHDPairAndKeepsDistinct() throws {
        try withTempDir { dir in
            let sd = try gradient(reversed: false, size: 300, to: dir, "sd")
            let hd = try gradient(reversed: false, size: 900, to: dir, "hd")   // same image, larger
            let other = try gradient(reversed: true, size: 300, to: dir, "other")
            let now = Date()
            let result = PhotoMatching.dedupHDDuplicates([
                item(sd,    fileSize: 100_000, date: now),
                item(hd,    fileSize: 300_000, date: now),
                item(other, fileSize: 100_000, date: now),
            ])
            XCTAssertEqual(result.count, 2, "SD/HD pair should collapse to one; distinct kept")
            XCTAssertTrue(result.contains { $0.url == hd },    "keep the larger HD copy")
            XCTAssertTrue(result.contains { $0.url == other }, "distinct photo survives")
        }
    }

    /// The Ben regression: two photos can be perceptually similar yet be DIFFERENT poses. Because
    /// same-quality-tier photos have near-equal file sizes, a small size difference is required to
    /// treat them as a twin — so two similar same-tier photos must NOT be merged.
    func testSimilarSameSizePhotosAreNotMerged() throws {
        try withTempDir { dir in
            let a = try gradient(reversed: false, size: 500, to: dir, "a")
            let b = try gradient(reversed: false, size: 500, to: dir, "b")   // ~identical, SAME size tier
            let now = Date()
            let result = PhotoMatching.dedupHDDuplicates([
                item(a, fileSize: 120_000, date: now),
                item(b, fileSize: 122_000, date: now),   // ratio ~1.0 → not a twin
            ])
            XCTAssertEqual(result.count, 2, "same-tier (equal-size) photos must never be collapsed")
        }
    }

    /// SD/HD go out together; a big time gap means different check-ins, so lookalikes across
    /// sends must not be merged even if they look like an SD/HD pair.
    func testDifferentSendNotMerged() throws {
        try withTempDir { dir in
            let sd = try gradient(reversed: false, size: 300, to: dir, "sd")
            let hd = try gradient(reversed: false, size: 900, to: dir, "hd")
            let t = Date()
            let result = PhotoMatching.dedupHDDuplicates([
                item(sd, fileSize: 100_000, date: t),
                item(hd, fileSize: 300_000, date: t.addingTimeInterval(600)),   // 10 min later
            ])
            XCTAssertEqual(result.count, 2, "an SD/HD-looking pair 10 min apart is not one check-in")
        }
    }

    // MARK: helpers

    private func withTempDir(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    private func item(_ url: URL, fileSize: Int, date: Date) -> WhatsAppMediaItem {
        WhatsAppMediaItem(url: url, date: date, fileSize: fileSize)
    }

    private func gradient(reversed: Bool, size: Int, to dir: URL, _ name: String) throws -> URL {
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
        let url = dir.appendingPathComponent("\(name).jpg")
        try data.write(to: url)
        return url
    }
}
