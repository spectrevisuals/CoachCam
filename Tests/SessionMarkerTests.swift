import XCTest

/// The clean-exit marker decides whether the next launch reports "previous session did not exit
/// cleanly", and remembers which recording was in flight so the launch scan can tell a
/// truncated recording from a healthy one. A wrong verdict here means either false alarms on
/// every launch or lost recordings that are never reported.
final class SessionMarkerTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionMarkerTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var fileURL: URL { directory.appendingPathComponent(SessionMarker.fileName) }

    private func recordOnDisk() -> SessionMarkerRecord? {
        (try? Data(contentsOf: fileURL)).flatMap(SessionMarkerRecord.decode)
    }

    /// A fresh marker over the same folder = the next launch of the app.
    private func launch(build: String = "83") -> (marker: SessionMarker, verdict: SessionMarkerVerdict) {
        let marker = SessionMarker(directory: directory)
        let verdict = marker.beginSession(build: build)
        marker.waitForPendingWrites()
        return (marker, verdict)
    }

    private let recording = "/Users/someone/Movies/CoachCap/WC 2026-11-16/Client_2026-11-21.mp4"

    // MARK: Launch verdicts

    func testFirstRunIsSilentAndWritesRunning() {
        let (_, verdict) = launch(build: "83")
        XCTAssertEqual(verdict, .noPreviousSession)
        let record = recordOnDisk()
        XCTAssertEqual(record?.schema, SessionMarkerRecord.currentSchema)
        XCTAssertEqual(record?.state, "running")
        XCTAssertEqual(record?.recordingState, "idle")
        XCTAssertEqual(record?.build, "83")
        XCTAssertNil(record?.inFlightPath)
        XCTAssertNil(record?.unfinalisedPaths)
    }

    func testNormalQuitThenLaunchIsClean() {
        let (first, _) = launch()
        first.markCleanExit()
        XCTAssertEqual(recordOnDisk()?.state, "clean")

        let (_, verdict) = launch()
        XCTAssertEqual(verdict, .exitedCleanly)
        XCTAssertEqual(recordOnDisk()?.state, "running", "the new session must be marked running again")
    }

    func testKilledWhileIdleIsReportedAsUnclean() {
        _ = launch(build: "82")                         // never writes clean
        let (_, verdict) = launch(build: "83")
        XCTAssertEqual(verdict, .didNotExitCleanly(recordingState: "idle", build: "82"))
    }

    func testKilledWhileRecordingReportsTheLastRecordingState() {
        let (first, _) = launch(build: "82")
        first.setRecordingState("starting")
        first.setRecordingState("recording")
        first.waitForPendingWrites()
        XCTAssertEqual(recordOnDisk()?.recordingState, "recording")

        let (_, verdict) = launch(build: "83")
        XCTAssertEqual(verdict, .didNotExitCleanly(recordingState: "recording", build: "82"))
        XCTAssertEqual(recordOnDisk()?.recordingState, "idle", "a new session starts idle")
    }

    func testUnreadableOrForeignFileIsTreatedAsFirstRun() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try Data("not json at all".utf8).write(to: fileURL)
        XCTAssertEqual(launch().verdict, .noPreviousSession)

        let future = #"{"schema":99,"state":"running","recordingState":"recording","build":"200"}"#
        try Data(future.utf8).write(to: fileURL)
        XCTAssertEqual(launch().verdict, .noPreviousSession)
    }

    // MARK: In-flight recording

    func testRecordingNeverFinalisedIsHandedToTheNextSessionOnce() {
        let (first, _) = launch()
        first.setRecordingState("recording")
        first.recordingStarted(path: recording)
        first.waitForPendingWrites()
        XCTAssertEqual(recordOnDisk()?.inFlightPath, recording)

        // Crash. Next launch inherits the path for the scan…
        let (second, verdict) = launch()
        XCTAssertEqual(verdict, .didNotExitCleanly(recordingState: "recording", build: "83"))
        XCTAssertEqual(second.unfinalisedPaths(), [recording])
        XCTAssertNil(recordOnDisk()?.inFlightPath)
        XCTAssertEqual(recordOnDisk()?.unfinalisedPaths, [recording])

        // …and forgets it once the scan has consumed it.
        second.clearUnfinalisedPaths([recording])
        second.waitForPendingWrites()
        XCTAssertEqual(second.unfinalisedPaths(), [])
        XCTAssertNil(recordOnDisk()?.unfinalisedPaths)

        second.markCleanExit()
        let (third, _) = launch()
        XCTAssertEqual(third.unfinalisedPaths(), [])
    }

    func testFinalisedRecordingIsNotHandedOn() {
        let (first, _) = launch()
        first.recordingStarted(path: recording)
        first.recordingFinalized()
        first.waitForPendingWrites()
        XCTAssertNil(recordOnDisk()?.inFlightPath)

        let (second, _) = launch()
        XCTAssertEqual(second.unfinalisedPaths(), [])
    }

    func testRecordingAbandonedMidFlightIsNotForgottenWhenAnotherOneStarts() {
        // Recording A is never finalised (its window was closed mid-recording). The coach
        // then records B in the same session, and B finalises normally.
        let abandoned = "/Users/someone/Movies/CoachCap/WC 2026-11-16/A_2026-11-21.mp4"
        let second = "/Users/someone/Movies/CoachCap/WC 2026-11-16/B_2026-11-21.mp4"
        let (first, _) = launch()
        first.recordingStarted(path: abandoned)
        first.recordingStarted(path: second)
        first.waitForPendingWrites()
        XCTAssertEqual(recordOnDisk()?.inFlightPath, second)
        XCTAssertEqual(recordOnDisk()?.unfinalisedPaths, [abandoned])

        first.recordingFinalized(path: second)
        first.waitForPendingWrites()
        XCTAssertNil(recordOnDisk()?.inFlightPath)
        XCTAssertEqual(recordOnDisk()?.unfinalisedPaths, [abandoned], "A must survive B's finalize")
        first.markCleanExit()

        // The next launch hands A to the scan, exactly once.
        let (next, _) = launch()
        XCTAssertEqual(next.unfinalisedPaths(), [abandoned])
    }

    func testStartingTheSameRecordingTwiceDoesNotListIt() {
        let (first, _) = launch()
        first.recordingStarted(path: recording)
        first.recordingStarted(path: recording)
        first.waitForPendingWrites()
        XCTAssertEqual(recordOnDisk()?.inFlightPath, recording)
        XCTAssertNil(recordOnDisk()?.unfinalisedPaths)
    }

    func testFinalizeThatFinishesAfterANewRecordingStartedForgetsOnlyItsOwnRecording() {
        // A is still finalising when B starts (B takes the in-flight slot and A is moved to
        // the list); then A's finalize finishes. A is healthy and must not be reported; B is
        // still in flight.
        let earlier = "/Users/someone/Movies/CoachCap/WC 2026-11-16/A_2026-11-21.mp4"
        let later = "/Users/someone/Movies/CoachCap/WC 2026-11-16/B_2026-11-21.mp4"
        let (first, _) = launch()
        first.recordingStarted(path: earlier)
        first.recordingStarted(path: later)
        first.recordingFinalized(path: earlier)
        first.waitForPendingWrites()
        XCTAssertEqual(recordOnDisk()?.inFlightPath, later)
        XCTAssertNil(recordOnDisk()?.unfinalisedPaths)

        let (next, _) = launch()                        // crash while B was recording
        XCTAssertEqual(next.unfinalisedPaths(), [later])
    }

    func testAbandonedRecordingsAreListedNewestFirstWithoutDuplicatesAndCapped() {
        let (first, _) = launch()
        for index in 1...12 {
            first.recordingStarted(path: "/a/\(index)_2026-11-21.mp4")
        }
        first.recordingStarted(path: "/a/8_2026-11-21.mp4")     // one that is already listed
        first.waitForPendingWrites()
        let listed = recordOnDisk()?.unfinalisedPaths ?? []
        XCTAssertEqual(listed.count, SessionMarker.maxUnfinalisedPaths)
        XCTAssertEqual(listed.first, "/a/12_2026-11-21.mp4")
        XCTAssertEqual(Set(listed).count, listed.count)
        XCTAssertEqual(recordOnDisk()?.inFlightPath, "/a/8_2026-11-21.mp4")

        // A crash now: the next launch gets every path once, the in-flight one first.
        let (next, _) = launch()
        let handedOn = next.unfinalisedPaths()
        XCTAssertEqual(handedOn.first, "/a/8_2026-11-21.mp4")
        XCTAssertEqual(Set(handedOn).count, handedOn.count)
        XCTAssertEqual(handedOn.count, SessionMarker.maxUnfinalisedPaths)
    }

    func testNormalQuitInTheMiddleOfARecordingStillHandsThePathOn() {
        let (first, _) = launch()
        first.setRecordingState("recording")
        first.recordingStarted(path: recording)
        first.markCleanExit()
        XCTAssertEqual(recordOnDisk()?.state, "clean")
        XCTAssertEqual(recordOnDisk()?.recordingState, "recording")
        XCTAssertEqual(recordOnDisk()?.inFlightPath, recording)

        let (second, verdict) = launch()
        XCTAssertEqual(verdict, .exitedCleanly)
        XCTAssertEqual(second.unfinalisedPaths(), [recording])
    }

    func testPathsSurviveASecondCrashBeforeTheScanRan() {
        let (first, _) = launch()
        first.recordingStarted(path: "/a/one_2026-11-20.mp4")
        first.waitForPendingWrites()

        let (second, _) = launch()                      // inherits "one", scan never runs
        second.recordingStarted(path: "/a/two_2026-11-21.mp4")
        second.waitForPendingWrites()

        let (third, _) = launch()
        XCTAssertEqual(third.unfinalisedPaths(), ["/a/two_2026-11-21.mp4", "/a/one_2026-11-20.mp4"])
    }

    // MARK: Inert until switched on

    func testNothingIsWrittenBeforeBeginSession() {
        let marker = SessionMarker(directory: directory)
        marker.setRecordingState("recording")
        marker.recordingStarted(path: recording)
        marker.recordingFinalized()
        marker.clearUnfinalisedPaths([recording])
        marker.markCleanExit()
        marker.waitForPendingWrites()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(marker.unfinalisedPaths(), [])
    }

    func testMarkerWithoutAFolderNeverDoesAnything() {
        let marker = SessionMarker(directory: nil)
        XCTAssertEqual(marker.beginSession(build: "83"), .noPreviousSession)
        marker.setRecordingState("recording")
        marker.recordingStarted(path: recording)
        marker.markCleanExit()
        marker.waitForPendingWrites()
        XCTAssertEqual(marker.unfinalisedPaths(), [])
    }

    // MARK: Pure logic

    func testVerdictRules() {
        XCTAssertEqual(SessionMarker.verdict(forPrevious: nil), .noPreviousSession)
        var record = SessionMarkerRecord(schema: 1, state: "clean", recordingState: "idle", build: "83",
                                         inFlightPath: nil, unfinalisedPaths: nil)
        XCTAssertEqual(SessionMarker.verdict(forPrevious: record), .exitedCleanly)
        record.state = "running"
        record.recordingState = "finalizing"
        XCTAssertEqual(SessionMarker.verdict(forPrevious: record),
                       .didNotExitCleanly(recordingState: "finalizing", build: "83"))
    }

    func testNextRecordCarriesPathsNewestFirstWithoutDuplicatesAndCapped() {
        let old = (1...12).map { "/old/\($0).mp4" }
        let previous = SessionMarkerRecord(schema: 1, state: "running", recordingState: "recording", build: "82",
                                           inFlightPath: "/new.mp4", unfinalisedPaths: ["/new.mp4", ""] + old)
        let next = SessionMarker.nextRecord(after: previous, build: "83")
        XCTAssertEqual(next.state, "running")
        XCTAssertEqual(next.recordingState, "idle")
        XCTAssertEqual(next.build, "83")
        XCTAssertNil(next.inFlightPath)
        XCTAssertEqual(next.unfinalisedPaths?.count, SessionMarker.maxUnfinalisedPaths)
        XCTAssertEqual(next.unfinalisedPaths?.first, "/new.mp4")
        XCTAssertEqual(next.unfinalisedPaths?[1], "/old/1.mp4")

        XCTAssertNil(SessionMarker.nextRecord(after: nil, build: "83").unfinalisedPaths)
    }

    func testRecordRoundTripsThroughJSON() throws {
        let record = SessionMarkerRecord(schema: 1, state: "running", recordingState: "paused", build: "83",
                                         inFlightPath: recording, unfinalisedPaths: ["/a.mp4"])
        let data = try XCTUnwrap(record.encoded())
        XCTAssertEqual(SessionMarkerRecord.decode(data), record)
    }
}

/// The launch scan's classification rule: which leftover files are reported, and as what.
final class RecordingsScanClassifierTests: XCTestCase {

    private func classify(_ name: String, _ size: Int, inFlight: Bool = false) -> RecordingFileClass? {
        RecordingsScanClassifier.classify(fileName: name, size: size, isUnfinalisedInFlight: inFlight)
    }

    func testEmptyFiles() {
        XCTAssertEqual(classify("Client_2026-11-21.mp4", 0), .empty)
        XCTAssertEqual(classify("Client_2026-11-21.mp4", 0, inFlight: true), .empty)
        XCTAssertEqual(classify("Client_2026-11-21.unfinished.mp4", 0), .emptyUnfinished)
        XCTAssertEqual(classify("Client_2026-11-21.flat.mp4", 0), .workfileEmpty)
        XCTAssertEqual(classify("Client_2026-11-21_edited.mp4", 0), .workfileEmpty)
        XCTAssertEqual(classify("Client_2026-11-21_edited_2.mp4", 0), .workfileEmpty)
        XCTAssertEqual(classify("Client_2026-11-21_3_edited_12.MP4", 0), .workfileEmpty)
    }

    func testFilesWithData() {
        XCTAssertEqual(classify("Client_2026-11-21.unfinished.mp4", 4_096), .unfinished)
        XCTAssertEqual(classify("Client_2026-11-21.mp4", 9_000_000, inFlight: true), .truncated)
        XCTAssertEqual(classify("Client_2026-11-21_2.mp4", 9_000_000, inFlight: true), .truncated)
    }

    func testHealthyAndIrrelevantFilesAreSkipped() {
        XCTAssertNil(classify("Client_2026-11-21.mp4", 9_000_000))
        XCTAssertNil(classify("Client_2026-11-21_2.mp4", 9_000_000))
        XCTAssertNil(classify("Client_2026-11-21.flat.mp4", 9_000_000))
        XCTAssertNil(classify("Client_2026-11-21_edited.mp4", 9_000_000))
        XCTAssertNil(classify("Client_2026-11-21_edited_3.mp4", 9_000_000, inFlight: true))
        XCTAssertNil(classify("CoachCam-error-log.txt", 0))
        XCTAssertNil(classify("WC 2026-11-16 transcripts.txt", 0))
        XCTAssertNil(classify("photo.jpg", 0))
    }

    func testEditedCopyNames() {
        XCTAssertTrue(RecordingsScanClassifier.isEditedCopyName("client_2026-11-21_edited.mp4"))
        XCTAssertTrue(RecordingsScanClassifier.isEditedCopyName("client_2026-11-21_edited_2.mp4"))
        XCTAssertFalse(RecordingsScanClassifier.isEditedCopyName("client_2026-11-21_2.mp4"))
        XCTAssertFalse(RecordingsScanClassifier.isEditedCopyName("edited_2026-11-21.mp4"))
        XCTAssertFalse(RecordingsScanClassifier.isEditedCopyName("client_edited_x.mp4"))
    }

    func testWeekFolderNames() {
        XCTAssertTrue(RecordingsScanClassifier.isWeekFolderName("WC 2026-11-16"))
        XCTAssertFalse(RecordingsScanClassifier.isWeekFolderName("WC 2026-11-1"))
        XCTAssertFalse(RecordingsScanClassifier.isWeekFolderName("WC 2026-11-16 "))
        XCTAssertFalse(RecordingsScanClassifier.isWeekFolderName("WC 2026/11/16"))
        XCTAssertFalse(RecordingsScanClassifier.isWeekFolderName("wc 2026-11-16"))
        XCTAssertFalse(RecordingsScanClassifier.isWeekFolderName("Jane Doe"))
        XCTAssertFalse(RecordingsScanClassifier.isWeekFolderName("CoachCap"))
        XCTAssertFalse(RecordingsScanClassifier.isWeekFolderName(""))
    }

    func testDedupeIDKeepsThePreviousReportersFormat() {
        XCTAssertEqual(RecordingsScanClassifier.dedupeID(path: "/Users/x/Movies/CoachCap/WC 2026-11-16/a.mp4", size: 0),
                       "/Users/x/Movies/CoachCap/WC 2026-11-16/a.mp4#0")
    }

    func testTokensSentWithTheScanEvent() {
        XCTAssertEqual(RecordingFileClass.allCases.map(\.rawValue),
                       ["empty", "empty_unfinished", "unfinished", "truncated", "workfile_empty"])
    }
}
