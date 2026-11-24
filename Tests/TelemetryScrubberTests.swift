import XCTest

/// The privacy scrubber is the last line of defence for text the crash-reporting SDK collects
/// by itself (exception reasons, crash info, binary image paths). Recording file names hold
/// CLIENT names and every path holds the macOS ACCOUNT name — if any case here regresses, that
/// content can leave the Mac.
final class TelemetryScrubberTests: XCTestCase {

    private let home = "/Users/jake"

    private func scrub(_ text: String) -> String {
        TelemetryScrubber.scrub(text, homeDirectory: home)
    }

    /// Nothing identifying may survive in `output`.
    private func assertNoLeak(_ output: String, file: StaticString = #filePath, line: UInt = #line) {
        for secret in ["Jane", "Doe", "jake", "Brien", "Smith", "gmail", "447700900123"] {
            XCTAssertFalse(output.contains(secret), "leaked “\(secret)” in: \(output)", file: file, line: line)
        }
    }

    // MARK: Recordings folder

    func testClientNamedRecordingPathCollapsesToTheRecordingsFolder() {
        let out = scrub("/Users/jake/Movies/CoachCap/WC 2026-11-16/Jane Doe_2026-11-21.mp4")
        XCTAssertEqual(out, "/Users/<redacted>/Movies/CoachCap")
        assertNoLeak(out)
    }

    func testUnfinishedFlatAndEditedPathsCollapseToo() {
        for name in ["Jane Doe_2026-11-21.unfinished.mp4",
                     "Jane Doe_2026-11-21.flat.mp4",
                     "Jane Doe_2026-11-21_edited.mp4",
                     "Jane Doe_2026-11-21_3_edited_2.mp4"] {
            let out = scrub("/Users/jake/Movies/CoachCap/WC 2026-11-16/\(name)")
            XCTAssertEqual(out, "/Users/<redacted>/Movies/CoachCap", name)
        }
    }

    func testNameWithApostropheAndCommaStillCollapses() {
        let out = scrub("could not open /Users/jake/Movies/CoachCap/WC 2026-11-16/O'Brien, Jane_2026-11-21.mp4")
        XCTAssertEqual(out, "could not open /Users/<redacted>/Movies/CoachCap")
        assertNoLeak(out)
    }

    func testRecordingsFolderItselfIsKept() {
        XCTAssertEqual(scrub("/Users/jake/Movies/CoachCap is missing"),
                       "/Users/<redacted>/Movies/CoachCap is missing")
    }

    // MARK: NSError-shaped strings

    func testNSErrorDescriptionWithNSFilePath() {
        let input = "Error Domain=NSCocoaErrorDomain Code=4 \"The file “Jane Doe_2026-11-21.mp4” doesn’t exist.\" "
            + "UserInfo={NSFilePath=/Users/jake/Movies/CoachCap/WC 2026-11-16/Jane Doe_2026-11-21.mp4, "
            + "NSUnderlyingError=0x600000c5d0b0 {Error Domain=NSPOSIXErrorDomain Code=2 \"No such file or directory\"}}"
        let expected = "Error Domain=NSCocoaErrorDomain Code=4 \"The file “<recording>.mp4” doesn’t exist.\" "
            + "UserInfo={NSFilePath=/Users/<redacted>/Movies/CoachCap, "
            + "NSUnderlyingError=0x600000c5d0b0 {Error Domain=NSPOSIXErrorDomain Code=2 \"No such file or directory\"}}"
        let out = scrub(input)
        XCTAssertEqual(out, expected)
        assertNoLeak(out)
    }

    func testNSErrorDescriptionWithFileURLAndSeveralKeys() {
        let input = "UserInfo={NSURL=file:///Users/jake/Movies/CoachCap/WC%202026-11-16/Jane%20Doe_2026-11-21.mp4, "
            + "NSFilePath=/Users/jake/Movies/CoachCap/WC 2026-11-16/Jane Doe_2026-11-21.mp4, "
            + "NSLocalizedDescription=The operation couldn’t be completed.}"
        let expected = "UserInfo={NSURL=file:///Users/<redacted>/Movies/CoachCap, "
            + "NSFilePath=/Users/<redacted>/Movies/CoachCap, "
            + "NSLocalizedDescription=The operation couldn’t be completed.}"
        let out = scrub(input)
        XCTAssertEqual(out, expected)
        assertNoLeak(out)
    }

    func testBareFileURL() {
        XCTAssertEqual(scrub("NSURL=file:///Users/jake/Movies/CoachCap/WC%202026-11-16/Jane%20Doe_2026-11-21.unfinished.mp4"),
                       "NSURL=file:///Users/<redacted>/Movies/CoachCap")
    }

    // MARK: Stand-alone recording names

    func testStandAloneRecordingNamesWithSpaces() {
        XCTAssertEqual(scrub("“Jane Doe_2026-11-21.mp4” couldn’t be copied to “CoachCam Backups”."),
                       "“<recording>.mp4” couldn’t be copied to “CoachCam Backups”.")
        XCTAssertEqual(scrub("trim failed: Jane Doe_2026-11-21_edited_2.mp4"),
                       "trim failed: <recording>.mp4")
        XCTAssertEqual(scrub("file=Jane Doe_2026-11-21_4.flat.mp4"),
                       "file=<recording>.mp4")
    }

    func testEditedCopyOfAnEditedCopy() {
        // The trim editor names its output `<source>_edited.mp4`, and that copy can be edited again.
        for name in ["Jane Doe_2026-11-21_edited_edited.mp4",
                     "Jane Doe_2026-11-21_edited_2_edited.mp4",
                     "Jane Doe_2026-11-21_3_edited_edited_2.mp4",
                     "Jane Doe_2026-11-21_edited.flat.mp4"] {
            let out = scrub("trim failed: \(name)")
            XCTAssertEqual(out, "trim failed: <recording>.mp4", name)
            assertNoLeak(out)
        }
    }

    func testStandAloneNameIsRedactedBackToStartOfLine() {
        // No separator before the name: everything back to the start of the line goes.
        let out = scrub("save failed for Jane Doe_2026-11-21.unfinished.mp4")
        XCTAssertEqual(out, "<recording>.mp4")
        assertNoLeak(out)
    }

    func testTwoRecordingNamesOnTwoLines() {
        let out = scrub("Jane Doe_2026-11-21.mp4\nMary Smith_2026-11-20_2.mp4")
        XCTAssertEqual(out, "<recording>.mp4\n<recording>.mp4")
    }

    func testRelativePathWithRecordingName() {
        let out = scrub("WC 2026-11-16/Jane Doe_2026-11-21.mp4")
        XCTAssertEqual(out, "WC 2026-11-16/<file>.mp4")
        assertNoLeak(out)
    }

    // MARK: Other locations

    func testVolumesPathCollapsesToARedactedVolume() {
        let out = scrub("/Volumes/Jane's SSD/Clients/Jane Doe/checkin_2026-11-21.mp4 could not be read")
        XCTAssertEqual(out, "/Volumes/<redacted>")
        assertNoLeak(out)
    }

    func testCloudStorageAccountIsRedacted() {
        let out = scrub("/Users/jake/Library/CloudStorage/GoogleDrive-jane@gmail.com/My Drive/CoachCam/Jane_2026-11-21.mp4")
        XCTAssertEqual(out, "/Users/<redacted>/Library/CloudStorage/<redacted>")
        assertNoLeak(out)
    }

    func testAppDataFoldersCollapseToTheirRoot() {
        XCTAssertEqual(scrub("/Users/jake/Library/Application Support/CoachCam/transcripts/Jane Doe_2026-11-21.json"),
                       "/Users/<redacted>/Library/Application Support/CoachCam")
        XCTAssertEqual(scrub("/Users/jake/Pictures/CoachCap/Jane before-after.jpg"),
                       "/Users/<redacted>/Pictures/CoachCap")
        let whatsApp = scrub("/Users/jake/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media/447700900123@s.whatsapp.net/a/b/photo.jpg")
        XCTAssertEqual(whatsApp, "/Users/<redacted>/Library/Group Containers/group.net.whatsapp.WhatsApp.shared")
        assertNoLeak(whatsApp)
        XCTAssertEqual(scrub("/Users/jake/Library/Group Containers/group.net.whatsapp.WhatsAppSMB.shared/ChatStorage.sqlite"),
                       "/Users/<redacted>/Library/Group Containers/group.net.whatsapp.WhatsAppSMB.shared")
    }

    func testPathsOutsideTheHomeFolderKeepTheFolderAndDropTheFileName() {
        XCTAssertEqual(scrub("/private/tmp/export/Jane photo 1.JPG"), "/private/tmp/export/<file>.JPG")
    }

    // MARK: Anywhere else below the home folder

    func testOtherHomePathsAreCutBackToTheHomeFolder() {
        // Folder names there are often client names, and a file can have any extension.
        XCTAssertEqual(scrub("/Users/jake/Desktop/Jane Doe.mov"), "/Users/<redacted>/<path>")
        XCTAssertEqual(scrub("/Users/jake/Desktop/Jane Doe/before.jpg"), "/Users/<redacted>/<path>")
        XCTAssertEqual(scrub("NSFilePath=/Users/jake/Documents/Clients/Jane Doe/progress.pdf"),
                       "NSFilePath=/Users/<redacted>/<path>")
        XCTAssertEqual(scrub("/Users/jake/Documents/Clients/Jane Doe/notes"), "/Users/<redacted>/<path>")
        // Where the path ends is ambiguous in free text, so too much goes rather than too little.
        let sentence = scrub("open(/Users/jake/Documents/notes about Jane.txt) failed")
        XCTAssertEqual(sentence, "open(/Users/<redacted>/<path>")
        assertNoLeak(sentence)
        // The coach's backup folder (iCloud Drive) is not one of the app's own folders.
        let backup = scrub("/Users/jake/Library/Mobile Documents/com~apple~CloudDocs/Jane Doe check-ins/WC 2026-11-16/Jane Doe_2026-11-21.mp4")
        XCTAssertEqual(backup, "/Users/<redacted>/<path>")
        assertNoLeak(backup)
    }

    func testOtherHomePathInsideAnNSErrorDumpStopsAtTheNextKey() {
        let input = "UserInfo={NSFilePath=/Users/jake/Documents/Clients/Jane Doe/progress.pdf, "
            + "NSUnderlyingError=0x600000c5d0b0 {Error Domain=NSPOSIXErrorDomain Code=2 \"No such file or directory\"}}"
        let out = scrub(input)
        XCTAssertEqual(out, "UserInfo={NSFilePath=/Users/<redacted>/<path>, "
            + "NSUnderlyingError=0x600000c5d0b0 {Error Domain=NSPOSIXErrorDomain Code=2 \"No such file or directory\"}}")
        assertNoLeak(out)
    }

    func testFolderThatOnlyStartsLikeAnAppFolderIsNotKept() {
        for path in ["/Users/jake/Movies/CoachCap Old/Jane Doe/clip.m4v",
                     "/Users/jake/Movies/CoachCapture/Jane/x.pdf",
                     "/Users/jake/Pictures/CoachCap copy/Jane before.gif"] {
            let out = scrub(path)
            XCTAssertEqual(out, "/Users/<redacted>/<path>", path)
            assertNoLeak(out)
        }
    }

    func testUnicodeClientNames() {
        XCTAssertEqual(scrub("Zoë Müller_2026-11-21.mp4"), "<recording>.mp4")
        XCTAssertEqual(scrub("trim failed: Zoë Müller_2026-11-21_edited.mp4"), "trim failed: <recording>.mp4")
        for path in ["/Users/jake/Documents/Clients/Zoë Müller/Zoë Müller_2026-11-21.mp4",
                     "/Users/jake/Documents/Clients/Zoë Müller/plan.csv",
                     "/Users/jake/Movies/CoachCap/WC 2026-11-16/Zoë Müller_2026-11-21.mp4",
                     "/Volumes/Zoë's SSD/Zoë Müller/checkin.mov"] {
            let out = scrub(path)
            XCTAssertFalse(out.contains("Zoë"), "leaked in: \(out)")
            XCTAssertFalse(out.contains("Müller"), "leaked in: \(out)")
            assertNoLeak(out)
        }
    }

    func testSourceFileInATrapMessageKeepsItsNameAndTheMessage() {
        // The path in a Swift / Objective-C trap message is the BUILD machine's. Its folders
        // go; the file name, the line and the reason (what makes the crash readable) stay.
        XCTAssertEqual(scrub("/Users/jake/Documents/ClaudeCode/CoachCap/CoachCap/Recording/AreaSelector.swift:124: Fatal error: init(coder:) not used"),
                       "/Users/<redacted>/<path>/AreaSelector.swift:124: Fatal error: init(coder:) not used")
        XCTAssertEqual(scrub("Assertion failed at /Users/jake/Library/Developer/Xcode/DerivedData/CoachCap-abc/SourcePackages/checkouts/sentry-cocoa/Sources/Sentry/SentryHub.m:120"),
                       "Assertion failed at /Users/<redacted>/<path>/SentryHub.m:120")
        // A FOLDER that merely ends in a source extension is not a source file.
        let folder = scrub("/Users/jake/Documents/x.swift/more/Jane/y.pdf")
        XCTAssertEqual(folder, "/Users/<redacted>/<path>")
        assertNoLeak(folder)
    }

    func testQuotedFileNameWithMediaExtension() {
        XCTAssertEqual(scrub("The file “Jane.mov” couldn’t be opened."),
                       "The file “<file>.mov” couldn’t be opened.")
        XCTAssertEqual(scrub("couldn't read \"Jane Doe.png\""), "couldn't read \"<file>.png\"")
    }

    // MARK: Account names

    func testAnotherUsersFolderIsRedactedWithoutLeavingATail() {
        XCTAssertEqual(scrub("/Users/jakeb/Documents/plan.txt"), "/Users/<redacted>/<path>")
        XCTAssertEqual(scrub("(/Users/someone)"), "(/Users/<redacted>)")
    }

    func testHomeFolderWithSpacesAndPercentEncoding() {
        let spaced = "/Users/John Smith"
        XCTAssertEqual(TelemetryScrubber.scrub("/Users/John Smith/Movies/CoachCap/a_2026-11-21.mp4", homeDirectory: spaced),
                       "/Users/<redacted>/Movies/CoachCap")
        XCTAssertEqual(TelemetryScrubber.scrub("file:///Users/John%20Smith/Desktop/a.mov", homeDirectory: spaced),
                       "file:///Users/<redacted>/<path>")
        XCTAssertEqual(TelemetryScrubber.scrub("file:///Users/John%20Smith/Library/Application%20Support/CoachCam/x.json", homeDirectory: spaced),
                       "file:///Users/<redacted>/Library/Application%20Support/CoachCam")
    }

    func testHomeFolderOutsideUsers() {
        let out = TelemetryScrubber.scrub("/Volumes/Data/jake/Movies/CoachCap/WC 2026-11-16/Jane_2026-11-21.mp4",
                                          homeDirectory: "/Volumes/Data/jake")
        XCTAssertEqual(out, "/Users/<redacted>/Movies/CoachCap")
    }

    // MARK: Things that must NOT change

    func testStringsWithoutPathsAreUntouched() {
        let untouched = [
            "",
            "CoachCam@1.9.5+83",
            "0x00000001045a3f20",
            "8A3F2C1E-9B4D-4E6F-A1B2-C3D4E5F60718",
            "CoachCam.RecordingSession.start(config:)",
            "$s8CoachCam16RecordingSessionC5startyyYaKF",
            "AVFoundationErrorDomain",
            "Code: -11800",
            "com.coachcam.app",
            "Europe/London",
            "Darwin Kernel Version 25.2.0: root:xnu-12377.61.12~1/RELEASE_ARM64_T6000",
            "App hanging for at least 5000 ms.",
            "EXC_BAD_ACCESS",
            "Attempted to dereference null pointer.",
            "WC 2026-11-16",
            "recorder state",
            "/usr/lib/system/libsystem_kernel.dylib",
            "/usr/lib/libsqlite3.dylib",
            "/System/Library/Frameworks/AVFoundation.framework/Versions/A/AVFoundation",
            "/Applications/CoachCam.app/Contents/MacOS/CoachCam",
            "/Applications/CoachCam.app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"
        ]
        for text in untouched {
            XCTAssertEqual(scrub(text), text)
        }
    }

    // MARK: Binary image paths

    func testImagePathKeepsTheBinaryName() {
        func image(_ path: String) -> String { TelemetryScrubber.scrubImagePath(path, homeDirectory: home) }
        XCTAssertEqual(image("/Users/jake/Applications/CoachCam.app/Contents/MacOS/CoachCam"),
                       "/Users/<redacted>/Applications/CoachCam.app/Contents/MacOS/CoachCam")
        XCTAssertEqual(image("/Users/jake/Library/Developer/Xcode/DerivedData/CoachCap-abc/Build/Products/Debug/CoachCam.app/Contents/MacOS/CoachCam"),
                       "/Users/<redacted>/Library/Developer/Xcode/DerivedData/CoachCap-abc/Build/Products/Debug/CoachCam.app/Contents/MacOS/CoachCam")
        XCTAssertEqual(image("/Volumes/CoachCam 1/CoachCam.app/Contents/MacOS/CoachCam"),
                       "/Volumes/<redacted>/CoachCam.app/Contents/MacOS/CoachCam")
        XCTAssertEqual(image("/System/Volumes/Data/Users/jake/Applications/CoachCam.app/Contents/MacOS/CoachCam"),
                       "/System/Volumes/Data/Users/<redacted>/Applications/CoachCam.app/Contents/MacOS/CoachCam")
        // System and app-bundle images are returned exactly as they were.
        for path in ["/usr/lib/dyld",
                     "/usr/lib/system/libdispatch.dylib",
                     "/Applications/CoachCam.app/Contents/MacOS/CoachCam",
                     "/Applications/CoachCam.app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle",
                     "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit"] {
            XCTAssertEqual(image(path), path)
        }
    }

    func testImagePathWithHomeOutsideUsers() {
        XCTAssertEqual(TelemetryScrubber.scrubImagePath("/Volumes/Data/jake smith/Applications/CoachCam.app/Contents/MacOS/CoachCam",
                                                        homeDirectory: "/Volumes/Data/jake smith"),
                       "/Users/<redacted>/Applications/CoachCam.app/Contents/MacOS/CoachCam")
    }

    // MARK: Structured values

    func testScrubValueWalksDictionariesAndArrays() {
        let deep: [String: Any] = ["deep": "/Users/jake/Desktop/Jane.mov"]
        let listValues: [Any] = ["Jane Doe_2026-11-21.mp4", 7, deep]
        let nested: [String: Any] = ["list": listValues]
        let input: [String: Any] = [
            "count": 3,
            "ok": true,
            "ratio": 0.5,
            "path": "/Users/jake/Movies/CoachCap/WC 2026-11-16/Jane Doe_2026-11-21.mp4",
            "nested": nested
        ]
        let out = TelemetryScrubber.scrubValue(input, homeDirectory: home) as? [String: Any]
        XCTAssertEqual(out?["count"] as? Int, 3)
        XCTAssertEqual(out?["ok"] as? Bool, true)
        XCTAssertEqual(out?["ratio"] as? Double, 0.5)
        XCTAssertEqual(out?["path"] as? String, "/Users/<redacted>/Movies/CoachCap")
        let list = (out?["nested"] as? [String: Any])?["list"] as? [Any]
        XCTAssertEqual(list?[0] as? String, "<recording>.mp4")
        XCTAssertEqual(list?[1] as? Int, 7)
        XCTAssertEqual((list?[2] as? [String: Any])?["deep"] as? String, "/Users/<redacted>/<path>")
    }

    // MARK: Robustness (the scrubber runs inside the SDK's send path: it must never crash)

    func testDoubleExtensionsDoNotOverlap() {
        let longName = String(repeating: "Jane Doe ", count: 20)
        XCTAssertEqual(scrub("/Users/jake/Desktop/\(longName)notes.txt.mp4"), "/Users/<redacted>/<path>")
        XCTAssertEqual(scrub("/private/tmp/\(longName)notes.txt.mp4"), "/private/tmp/<file>.mp4")
        XCTAssertEqual(scrub("/tmp/a.mov.json.plist and /tmp/b.png"), "/tmp/<file>.plist and /tmp/<file>.png")
        XCTAssertEqual(scrub("/tmp/x/Jane.mp4.mp4.mp4"), "/tmp/x/<file>.mp4")
        assertNoLeak(scrub("Jane Doe_2026-11-21.mp4Jane Doe_2026-11-20_edited.mp4.flat.mp4"))
    }

    func testRandomPathSoupNeverCrashesOrKeepsTheHomeFolder() {
        // Deterministic pseudo-random strings built from the pieces that drive the rules.
        let pieces = ["/", "/Users/jake", "/Users/", "/Volumes/", "/Movies/CoachCap", "/Pictures/CoachCap",
                      "/Library/Application Support/CoachCam", "/Library/CloudStorage/", "Jane Doe", "_2026-11-21",
                      "_2", ".unfinished", ".flat", "_edited", ".mp4", ".MOV", ".json", ".plist", ".db", " ", ", ",
                      "NSFilePath=", "NSURL=file://", "“", "”", "\"", "{", "}", "|", "\n", ":", "=", "%20", "'", "(", ")",
                      "<redacted>", "<file>", "<recording>", "0x1045a3f20", "é", "🙂", "."]
        var state: UInt64 = 0x9E3779B97F4A7C15
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
        for _ in 0..<4_000 {
            var text = ""
            for _ in 0..<(1 + next(14)) { text += pieces[next(pieces.count)] }
            let out = scrub(text)
            XCTAssertFalse(out.contains("/Users/jake/"), "home folder survived in: \(out)  (from: \(text))")
            _ = TelemetryScrubber.scrubImagePath(text, homeDirectory: home)
            _ = TelemetryScrubber.sanitizedErrorDomain(text, homeDirectory: home)
        }
    }

    // MARK: Bounds

    func testVeryLongTextIsCutBeforeScrubbing() {
        let long = String(repeating: "a", count: 20_000) + " /Users/jake/Movies/CoachCap/Jane Doe_2026-11-21.mp4"
        let out = scrub(long)
        XCTAssertLessThanOrEqual(out.count, TelemetryScrubber.maxLength + 1)
        assertNoLeak(out)
    }

    // MARK: Error domains

    func testErrorDomainIsReducedToSafeCharacters() {
        XCTAssertEqual(TelemetryScrubber.sanitizedErrorDomain("AVFoundationErrorDomain"), "AVFoundationErrorDomain")
        XCTAssertEqual(TelemetryScrubber.sanitizedErrorDomain("com.apple.coreaudio.avfaudio"), "com.apple.coreaudio.avfaudio")
        XCTAssertEqual(TelemetryScrubber.sanitizedErrorDomain("CoachCam.CCError"), "CoachCam.CCError")
        XCTAssertEqual(TelemetryScrubber.sanitizedErrorDomain("bad domain: “x” (y)"), "baddomainxy")
        XCTAssertEqual(TelemetryScrubber.sanitizedErrorDomain(""), "unknown")
        XCTAssertEqual(TelemetryScrubber.sanitizedErrorDomain("———"), "unknown")
        XCTAssertEqual(TelemetryScrubber.sanitizedErrorDomain(String(repeating: "d", count: 200)).count, 80)
        let withPath = TelemetryScrubber.sanitizedErrorDomain("failed at /Users/jake/Movies/CoachCap/Jane Doe_2026-11-21.mp4",
                                                              homeDirectory: home)
        assertNoLeak(withPath)
    }

    // MARK: DSN shape

    func testWellFormedDSNs() {
        let dsn = "https://0123456789abcdef0123456789abcdef@o123456.ingest.de.sentry.io/4501234567890123"
        XCTAssertEqual(TelemetryDSN.wellFormed(dsn), dsn)
        XCTAssertEqual(TelemetryDSN.wellFormed("  \(dsn)\n"), dsn)
        XCTAssertEqual(TelemetryDSN.wellFormed("https://key@sentry.example.com:8443/prefix/42"),
                       "https://key@sentry.example.com:8443/prefix/42")
    }

    func testEmptyOrMalformedDSNsMeanNoTelemetry() {
        let bad: [String?] = [
            nil,
            "",
            "   ",
            "$(SENTRY_DSN)",                       // build setting never expanded
            "https:",                              // what an xcconfig makes of an unescaped DSN
            "https:/$()/key@o1.ingest.sentry.io/1",
            "http://key@o1.ingest.sentry.io/1",    // not https
            "https://o1.ingest.sentry.io/1",       // no key
            "https://key@o1.ingest.sentry.io/",    // no project id
            "https://key@o1.ingest.sentry.io/abc", // project id not a number
            "https://key@/1",
            "key@o1.ingest.sentry.io/1"
        ]
        for value in bad {
            XCTAssertNil(TelemetryDSN.wellFormed(value), "accepted: \(value ?? "nil")")
        }
    }
}
