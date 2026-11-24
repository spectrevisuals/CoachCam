import Foundation

// Clean-exit marker + the classification rule for the launch scan.
//
// Foundation-only on purpose: this file is also compiled into the unit-test target
// (`Tests/SessionMarkerTests.swift`). It must never import the Sentry module, and nothing in
// it sends anything anywhere — it only reads and writes one small local file.

// MARK: - The state file

/// Contents of `~/Library/Application Support/CoachCam/session-state.json`.
///
/// The app writes `running` when it launches and `clean` when it quits normally. If the next
/// launch still finds `running`, the previous session ended without a normal quit (crash,
/// force quit, power loss, kill) — and `recordingState` says what the recorder was doing.
///
/// `inFlightPath` and `unfinalisedPaths` hold recording paths (which contain client names and
/// the macOS account name). They are LOCAL ONLY: they are compared against files on this Mac by
/// the launch scan and are never put into a telemetry event.
struct SessionMarkerRecord: Codable, Equatable {
    static let currentSchema = 1
    static let stateRunning = "running"
    static let stateClean = "clean"
    static let recordingIdle = "idle"

    /// File-format version. A file with a different version is ignored (treated as absent).
    var schema: Int
    /// `running` or `clean`.
    var state: String
    /// `idle`, `starting`, `recording`, `paused` or `finalizing`.
    var recordingState: String
    /// CFBundleVersion of the app that wrote the file.
    var build: String
    /// LOCAL ONLY. The recording being written right now: set when a start succeeds, cleared
    /// when finalize has finished. Still set at the next launch = that file was never finalised.
    var inFlightPath: String?
    /// LOCAL ONLY. Never-finalised recordings inherited from earlier sessions, kept until the
    /// launch scan has looked at them.
    var unfinalisedPaths: [String]?

    static func decode(_ data: Data) -> SessionMarkerRecord? {
        guard let record = try? JSONDecoder().decode(SessionMarkerRecord.self, from: data),
              record.schema == currentSchema else { return nil }
        return record
    }

    func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(self)
    }
}

/// What the previous session's file says about how that session ended.
enum SessionMarkerVerdict: Equatable {
    /// No (readable) file: first run with this scheme. Stay silent.
    case noPreviousSession
    /// The previous session quit normally.
    case exitedCleanly
    /// The previous session never wrote `clean`.
    case didNotExitCleanly(recordingState: String, build: String)
}

/// Owns the state file. All writes happen on a private serial queue, so recording start/stop
/// never waits on the disk; only the final `clean` write at quit is synchronous.
///
/// The marker is INERT until `beginSession` is called: every other call is then a no-op and no
/// file is read or written. `Telemetry.start()` calls `beginSession` only when telemetry is
/// really on (a DSN is configured, the coach has not opted out, not an autotest run).
final class SessionMarker: @unchecked Sendable {

    static let fileName = "session-state.json"
    /// Upper bound on inherited never-finalised paths, so the file cannot grow without limit.
    static let maxUnfinalisedPaths = 8

    /// The app-wide marker in `~/Library/Application Support/CoachCam/`.
    static let shared = SessionMarker(directory: defaultDirectory())

    static func defaultDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("CoachCam", isDirectory: true)
    }

    private let directory: URL?
    private let queue = DispatchQueue(label: "com.coachcam.session-marker", qos: .utility)
    // Both only touched on `queue`.
    private var record: SessionMarkerRecord?
    private var active = false

    /// - Parameter directory: folder that holds the state file (injected in tests). `nil`
    ///   makes the marker permanently inert.
    init(directory: URL?) {
        self.directory = directory
    }

    private var fileURL: URL? {
        directory?.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    // MARK: Pure decision logic

    static func verdict(forPrevious previous: SessionMarkerRecord?) -> SessionMarkerVerdict {
        guard let previous else { return .noPreviousSession }
        if previous.state == SessionMarkerRecord.stateRunning {
            return .didNotExitCleanly(recordingState: previous.recordingState, build: previous.build)
        }
        return .exitedCleanly
    }

    /// The record this session starts with: `running`, recorder idle, and every recording the
    /// previous sessions left un-finalised carried over for the launch scan (newest first).
    static func nextRecord(after previous: SessionMarkerRecord?, build: String) -> SessionMarkerRecord {
        var carried: [String] = []
        if let path = previous?.inFlightPath, !path.isEmpty { carried.append(path) }
        for path in previous?.unfinalisedPaths ?? [] where !path.isEmpty && !carried.contains(path) {
            carried.append(path)
        }
        if carried.count > maxUnfinalisedPaths {
            carried = Array(carried.prefix(maxUnfinalisedPaths))
        }
        return SessionMarkerRecord(schema: SessionMarkerRecord.currentSchema,
                                   state: SessionMarkerRecord.stateRunning,
                                   recordingState: SessionMarkerRecord.recordingIdle,
                                   build: build,
                                   inFlightPath: nil,
                                   unfinalisedPaths: carried.isEmpty ? nil : carried)
    }

    // MARK: Launch

    /// Reads what the previous session left, switches the marker on and writes `running` for
    /// this session (the write itself is queued, not waited for). Call once, at launch.
    @discardableResult
    func beginSession(build: String) -> SessionMarkerVerdict {
        guard let fileURL else { return .noPreviousSession }
        let verdict: SessionMarkerVerdict = queue.sync {
            let previous = (try? Data(contentsOf: fileURL)).flatMap(SessionMarkerRecord.decode)
            record = Self.nextRecord(after: previous, build: build)
            active = true
            return Self.verdict(forPrevious: previous)
        }
        queue.async { self.write() }
        return verdict
    }

    // MARK: During the session (cheap, non-blocking, any thread)

    /// Persists the recorder state (`idle`, `starting`, `recording`, `paused`, `finalizing`).
    func setRecordingState(_ state: String) {
        mutate { $0.recordingState = state }
    }

    /// A recording's file now exists and is being written. LOCAL ONLY — see the record's notes.
    ///
    /// There is one in-flight slot. If it still holds an EARLIER recording — one whose finalize
    /// never finished, e.g. the recorder's window was closed mid-recording — that path is not
    /// forgotten: it moves to the never-finalised list, so the next launch's scan still sees it.
    func recordingStarted(path: String) {
        mutate { record in
            if let abandoned = record.inFlightPath, !abandoned.isEmpty, abandoned != path {
                var carried = [abandoned]
                for old in record.unfinalisedPaths ?? [] where !old.isEmpty && !carried.contains(old) {
                    carried.append(old)
                }
                record.unfinalisedPaths = Array(carried.prefix(Self.maxUnfinalisedPaths))
            }
            record.inFlightPath = path
        }
    }

    /// Finalize has finished (saved, salvaged or failed): the file is no longer in flight.
    ///
    /// - Parameter path: the recording whose finalize finished. With a path, only THAT
    ///   recording is forgotten (the in-flight slot is left alone if a newer recording has
    ///   taken it, and the path is taken off the never-finalised list). Without one, the
    ///   in-flight slot is simply emptied.
    func recordingFinalized(path: String? = nil) {
        mutate { record in
            guard let path else {
                record.inFlightPath = nil
                return
            }
            if record.inFlightPath == path {
                record.inFlightPath = nil
            }
            if let listed = record.unfinalisedPaths, listed.contains(path) {
                let remaining = listed.filter { $0 != path }
                record.unfinalisedPaths = remaining.isEmpty ? nil : remaining
            }
        }
    }

    /// Recordings that earlier sessions left un-finalised (for the launch scan).
    func unfinalisedPaths() -> [String] {
        queue.sync { active ? (record?.unfinalisedPaths ?? []) : [] }
    }

    /// The launch scan has looked at these paths; forget them.
    func clearUnfinalisedPaths(_ consumed: [String]) {
        guard !consumed.isEmpty else { return }
        mutate { record in
            let remaining = (record.unfinalisedPaths ?? []).filter { !consumed.contains($0) }
            record.unfinalisedPaths = remaining.isEmpty ? nil : remaining
        }
    }

    // MARK: Quit

    /// Writes `clean` and waits for it — call from the will-terminate notification. The
    /// recorder state and any in-flight path are kept as they are: a normal quit in the middle
    /// of a recording still leaves a file that was never finalised.
    func markCleanExit() {
        queue.sync {
            guard active, record != nil else { return }
            record?.state = SessionMarkerRecord.stateClean
            write()
        }
    }

    /// Blocks until every queued write has finished. For tests.
    func waitForPendingWrites() {
        queue.sync { }
    }

    // MARK: Implementation

    private func mutate(_ change: @escaping (inout SessionMarkerRecord) -> Void) {
        queue.async {
            guard self.active, var current = self.record else { return }
            let before = current
            change(&current)
            guard current != before else { return }
            self.record = current
            self.write()
        }
    }

    /// On `queue`. A small atomic write; failures are ignored (the marker is best-effort and
    /// must never surface an error to the app).
    private func write() {
        guard let directory, let fileURL, let data = record?.encoded() else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - Launch-scan classification

/// What kind of problem a leftover `.mp4` in the recordings folder is. The raw value is the
/// token sent with the scan's warning event (never the file's name or path).
enum RecordingFileClass: String, CaseIterable {
    /// 0 bytes under its normal name: the start failed, or the app died before the first data.
    case empty
    /// 0 bytes and named `.unfinished.mp4`: the app handled a failed save with nothing usable.
    case emptyUnfinished = "empty_unfinished"
    /// `.unfinished.mp4` with data in it: a failed save that may be recoverable.
    case unfinished
    /// Has data and a normal name, but is the recording the session marker says was never
    /// finalised (crash, force quit or quit in the middle of recording).
    case truncated
    /// A 0-byte temporary work file: `.flat.mp4` (audio merge) or `_edited[_n].mp4` (trim copy).
    case workfileEmpty = "workfile_empty"
}

/// Pure rules for the launch scan (`RecordingsHealthScan`), kept here so they are unit-tested.
enum RecordingsScanClassifier {

    /// - Parameters:
    ///   - fileName: last path component only.
    ///   - size: size in bytes.
    ///   - isUnfinalisedInFlight: the file's path is one the session marker recorded as in
    ///     flight and never finalised.
    /// - Returns: the class to report, or nil for a healthy / irrelevant file.
    static func classify(fileName: String, size: Int, isUnfinalisedInFlight: Bool) -> RecordingFileClass? {
        let name = fileName.lowercased()
        guard name.hasSuffix(".mp4") else { return nil }

        if name.hasSuffix(".unfinished.mp4") {
            return size == 0 ? .emptyUnfinished : .unfinished
        }
        if name.hasSuffix(".flat.mp4") || isEditedCopyName(name) {
            return size == 0 ? .workfileEmpty : nil
        }
        if size == 0 { return .empty }
        return isUnfinalisedInFlight ? .truncated : nil
    }

    /// `<base>_edited.mp4` or `<base>_edited_<n>.mp4` (lower-cased name).
    static func isEditedCopyName(_ lowercasedName: String) -> Bool {
        guard lowercasedName.hasSuffix(".mp4") else { return false }
        let stem = lowercasedName.dropLast(4)
        if stem.hasSuffix("_edited") { return true }
        guard let underscore = stem.lastIndex(of: "_") else { return false }
        let digits = stem[stem.index(after: underscore)...]
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
        return stem[..<underscore].hasSuffix("_edited")
    }

    /// True for the app's own week folders, `WC yyyy-MM-dd`. Only this yes/no is ever sent —
    /// a folder the coach made by hand could be named after a client.
    static func isWeekFolderName(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars)
        guard scalars.count == 13, name.hasPrefix("WC ") else { return false }
        for (index, scalar) in scalars.enumerated() where index >= 3 {
            let isDash = index == 7 || index == 10
            if isDash {
                if scalar != "-" { return false }
            } else if !(scalar.value >= 48 && scalar.value <= 57) {
                return false
            }
        }
        return true
    }

    /// Local de-duplication id, unchanged from the previous reporter (`<absolute path>#<size>`)
    /// so no Mac re-reports old files after updating. Stored in UserDefaults only; never sent.
    static func dedupeID(path: String, size: Int) -> String {
        "\(path)#\(size)"
    }
}
