import XCTest

/// "find in recording" phrase matching. Wrong matches send the coach's cut to the wrong
/// timestamp, so the matching rules are pinned down here.
final class TranscriptSearchTests: XCTestCase {

    private func words(_ pairs: [(String, Double)]) -> [VideoTranscriber.Word] {
        pairs.map { VideoTranscriber.Word(text: $0.0, time: $0.1, duration: 0.3) }
    }

    private let sample: [VideoTranscriber.Word] = [
        ("Okay", 0.0), ("so", 0.4), ("sorry,", 0.8), ("let", 1.2), ("me", 1.5),
        ("start", 1.9), ("again.", 2.3), ("Your", 5.0), ("squat", 5.4), ("depth", 5.9),
        ("is", 6.2), ("looking", 6.5), ("great", 7.0), ("this", 7.4), ("week.", 7.7),
        ("Sorry", 12.0), ("about", 12.4), ("the", 12.7), ("noise.", 13.0),
    ].map { VideoTranscriber.Word(text: $0.0, time: $0.1, duration: 0.3) }

    func testSingleWordCaseInsensitive() {
        let m = VideoTranscriber.search("sorry", in: sample)
        XCTAssertEqual(m.count, 2)
        XCTAssertEqual(m[0].time, 0.8, accuracy: 0.001)
        XCTAssertEqual(m[1].time, 12.0, accuracy: 0.001)
    }

    func testPunctuationIgnored() {
        // "noise." in the transcript still matches the query "noise"
        XCTAssertEqual(VideoTranscriber.search("noise", in: sample).count, 1)
    }

    func testMultiWordPhrase() {
        let m = VideoTranscriber.search("let me start again", in: sample)
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m[0].time, 1.2, accuracy: 0.001)
    }

    func testPrefixMatchesLongerWord() {
        // "look" should find "looking"
        let m = VideoTranscriber.search("look", in: sample)
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m[0].time, 6.5, accuracy: 0.001)
    }

    func testNoMatch() {
        XCTAssertTrue(VideoTranscriber.search("deadlift", in: sample).isEmpty)
    }

    func testPhraseAcrossSentenceBoundaryStillLiteral() {
        // words are matched positionally — "again your" spans the sentence gap and matches
        XCTAssertEqual(VideoTranscriber.search("again your", in: sample).count, 1)
    }

    func testSnippetContainsContext() {
        let m = VideoTranscriber.search("squat", in: sample)
        XCTAssertEqual(m.count, 1)
        XCTAssertTrue(m[0].snippet.contains("squat"))
        XCTAssertTrue(m[0].snippet.contains("depth"), "snippet should include following words")
    }

    func testEmptyAndWhitespaceQueries() {
        XCTAssertTrue(VideoTranscriber.search("", in: sample).isEmpty)
        XCTAssertTrue(VideoTranscriber.search("   ", in: sample).isEmpty)
    }

    func testQueryLongerThanTranscript() {
        let tiny = words([("hello", 0.0)])
        XCTAssertTrue(VideoTranscriber.search("hello there coach", in: tiny).isEmpty)
    }

    func testMatchesAreInTimeOrder() {
        let m = VideoTranscriber.search("sorry", in: sample)
        XCTAssertEqual(m.map(\.time), m.map(\.time).sorted())
    }
}
