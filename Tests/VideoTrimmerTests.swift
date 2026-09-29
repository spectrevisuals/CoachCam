import XCTest

/// The cut/keep arithmetic behind the trim editor. A wrong kept-range means a coach's cut
/// lands in the wrong place or content silently vanishes — cheap to guard exhaustively.
final class VideoTrimmerTests: XCTestCase {

    func testNoCutsKeepsEverything() {
        let kept = VideoTrimmer.keptRanges(duration: 60, cuts: [])
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept[0].lowerBound, 0, accuracy: 0.001)
        XCTAssertEqual(kept[0].upperBound, 60, accuracy: 0.001)
    }

    func testSingleMiddleCut() {
        let kept = VideoTrimmer.keptRanges(duration: 60, cuts: [20...30])
        XCTAssertEqual(kept.count, 2)
        XCTAssertEqual(kept[0].upperBound, 20, accuracy: 0.001)
        XCTAssertEqual(kept[1].lowerBound, 30, accuracy: 0.001)
        XCTAssertEqual(kept[1].upperBound, 60, accuracy: 0.001)
    }

    func testCutAtVeryStartAndEnd() {
        let kept = VideoTrimmer.keptRanges(duration: 60, cuts: [0...5, 55...60])
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept[0].lowerBound, 5, accuracy: 0.001)
        XCTAssertEqual(kept[0].upperBound, 55, accuracy: 0.001)
    }

    func testOverlappingCutsMerge() {
        let kept = VideoTrimmer.keptRanges(duration: 60, cuts: [10...25, 20...35, 30...40])
        XCTAssertEqual(kept.count, 2)
        XCTAssertEqual(kept[0].upperBound, 10, accuracy: 0.001)
        XCTAssertEqual(kept[1].lowerBound, 40, accuracy: 0.001)
    }

    func testUnsortedCutsAreHandled() {
        let kept = VideoTrimmer.keptRanges(duration: 60, cuts: [40...50, 5...10])
        XCTAssertEqual(kept.count, 3)
        XCTAssertEqual(kept[1].lowerBound, 10, accuracy: 0.001)
        XCTAssertEqual(kept[1].upperBound, 40, accuracy: 0.001)
    }

    func testCutsClampedToDuration() {
        let kept = VideoTrimmer.keptRanges(duration: 30, cuts: [25...99])
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept[0].upperBound, 25, accuracy: 0.001)
    }

    func testWholeVideoCutLeavesNothing() {
        XCTAssertTrue(VideoTrimmer.keptRanges(duration: 30, cuts: [0...30]).isEmpty)
    }

    func testSliverUnderTenthOfSecondDropped() {
        // Cuts 0-29.95 leave a 0.05 s tail — too short to keep.
        XCTAssertTrue(VideoTrimmer.keptRanges(duration: 30, cuts: [0...29.95]).isEmpty)
    }

    func testAdjacentCutsBehaveLikeOneCut() {
        let kept = VideoTrimmer.keptRanges(duration: 60, cuts: [10...20, 20...30])
        XCTAssertEqual(kept.count, 2)
        XCTAssertEqual(kept[1].lowerBound, 30, accuracy: 0.001)
    }

    /// Randomised invariant sweep: whatever the cuts, kept ranges must be sorted,
    /// non-overlapping, inside [0, duration], and never intersect a cut's interior.
    func testKeptRangesInvariantsUnderRandomCuts() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let duration = Double.random(in: 1...600, using: &rng)
            let cuts: [ClosedRange<Double>] = (0..<Int.random(in: 0...6, using: &rng)).map { _ in
                let a = Double.random(in: -10...duration + 10, using: &rng)
                let b = a + Double.random(in: 0...duration / 2, using: &rng)
                return a...b
            }
            let kept = VideoTrimmer.keptRanges(duration: duration, cuts: cuts)
            var lastEnd = -Double.infinity
            for k in kept {
                XCTAssertGreaterThanOrEqual(k.lowerBound, 0)
                XCTAssertLessThanOrEqual(k.upperBound, duration + 0.001)
                XCTAssertGreaterThan(k.upperBound, k.lowerBound)
                XCTAssertGreaterThanOrEqual(k.lowerBound, lastEnd - 0.001, "kept ranges overlap")
                lastEnd = k.upperBound
                for c in cuts {
                    let lo = max(0, c.lowerBound), hi = min(duration, c.upperBound)
                    guard hi > lo else { continue }
                    let overlap = min(k.upperBound, hi) - max(k.lowerBound, lo)
                    XCTAssertLessThanOrEqual(overlap, 0.001, "kept range intersects a cut")
                }
            }
        }
    }

    func testEditedOutputURLNamingAndCollision() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("trimtest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("Client_2026-09-28.mp4")
        FileManager.default.createFile(atPath: src.path, contents: Data())

        let first = VideoTrimmer.editedOutputURL(for: src)
        XCTAssertEqual(first.lastPathComponent, "Client_2026-09-28_edited.mp4")
        FileManager.default.createFile(atPath: first.path, contents: Data())
        let second = VideoTrimmer.editedOutputURL(for: src)
        XCTAssertEqual(second.lastPathComponent, "Client_2026-09-28_edited_2.mp4")
    }
}
