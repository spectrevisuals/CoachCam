import AppKit
import XCTest

/// Geometry of the exported before/after comparison JPEGs.
final class PhotoStitcherTests: XCTestCase {

    private func img(_ w: CGFloat, _ h: CGFloat) -> NSImage {
        let i = NSImage(size: NSSize(width: w, height: h))
        i.lockFocus(); NSColor.gray.setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill(); i.unlockFocus()
        return i
    }

    func testSinglePairDimensions() {
        var o = PhotoStitcher.Options()
        o.showColumnHeaders = true
        // 1:1 images at rowHeight 520 → each column 520 wide + 5 divider.
        let out = PhotoStitcher.stitch(pairs: [(img(100, 100), img(100, 100))], options: o)
        XCTAssertNotNil(out)
        XCTAssertEqual(out!.size.width, 520 + 5 + 520, accuracy: 1)
        XCTAssertEqual(out!.size.height, o.headerHeight + o.rowHeight, accuracy: 1)
    }

    func testTwoPairsAddRowAndSeparator() {
        var o = PhotoStitcher.Options()
        o.showColumnHeaders = true
        let pair: (NSImage?, NSImage?) = (img(100, 100), img(100, 100))
        let out = PhotoStitcher.stitch(pairs: [pair, pair], options: o)
        XCTAssertEqual(out!.size.height,
                       o.headerHeight + 2 * o.rowHeight + o.rowDividerHeight, accuracy: 1)
    }

    func testClientNameBannerAddsHeight() {
        var o = PhotoStitcher.Options()
        o.showColumnHeaders = false
        o.clientName = "Rosie"
        let out = PhotoStitcher.stitch(pairs: [(img(100, 100), img(100, 100))], options: o)
        XCTAssertEqual(out!.size.height, o.clientNameHeight + o.rowHeight, accuracy: 1)
    }

    func testLogoDoesNotChangeCanvasSize() {
        var plain = PhotoStitcher.Options(); plain.clientName = "Rosie"
        var branded = plain; branded.logo = img(300, 100)
        let a = PhotoStitcher.stitch(pairs: [(img(100, 100), img(100, 100))], options: plain)!
        let b = PhotoStitcher.stitch(pairs: [(img(100, 100), img(100, 100))], options: branded)!
        XCTAssertEqual(a.size, b.size)
    }

    func testNilImagesStillProduceOutput() {
        XCTAssertNotNil(PhotoStitcher.stitch(pairs: [(nil, img(100, 100))]))
        XCTAssertNil(PhotoStitcher.stitch(pairs: [(nil, nil)]), "empty pair set → nil, not a blank export")
    }

    func testExportJPEGWritesDecodableFile() throws {
        let out = PhotoStitcher.stitch(pairs: [(img(50, 50), img(50, 50))])!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stitch-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try PhotoStitcher.exportJPEG(out, to: url)
        XCTAssertNotNil(NSImage(contentsOf: url))
    }
}
