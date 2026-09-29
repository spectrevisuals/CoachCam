import XCTest

/// Output-size selection for recordings: native aspect, capped at 1920 wide, even dimensions
/// (H.264 requires even). A wrong size here = stretched or unencodable recordings.
final class DisplayListTests: XCTestCase {
    func test4KDisplayCapsTo1920KeepingAspect() {
        let d = DisplayOption(id: 1, name: "4K", pixelSize: CGSize(width: 3840, height: 2160))
        XCTAssertEqual(d.recommendedOutputSize, CGSize(width: 1920, height: 1080))
    }

    func testScaledTallDisplayKeepsAspectAndEvenDims() {
        // Jake's 4K scaled mode: 3840×2492 backing → 1920 wide, even height.
        let d = DisplayOption(id: 1, name: "x", pixelSize: CGSize(width: 3840, height: 2492))
        let out = d.recommendedOutputSize
        XCTAssertEqual(out.width, 1920)
        XCTAssertEqual(Int(out.height) % 2, 0, "H.264 needs even dimensions")
        XCTAssertEqual(out.height, (1920 * 2492 / 3840).rounded(.down), accuracy: 2)
    }

    func testSmallDisplayNotUpscaled() {
        let d = DisplayOption(id: 1, name: "x", pixelSize: CGSize(width: 1440, height: 900))
        XCTAssertEqual(d.recommendedOutputSize.width, 1440)
    }

    func testZeroSizeFallsBackTo1080p() {
        let d = DisplayOption(id: 1, name: "x", pixelSize: .zero)
        XCTAssertEqual(d.recommendedOutputSize, CGSize(width: 1920, height: 1080))
    }

    func testOddHeightRoundsToEven() {
        let d = DisplayOption(id: 1, name: "x", pixelSize: CGSize(width: 1919, height: 1081))
        let out = d.recommendedOutputSize
        XCTAssertEqual(Int(out.width) % 2, 0)
        XCTAssertEqual(Int(out.height) % 2, 0)
    }
}
