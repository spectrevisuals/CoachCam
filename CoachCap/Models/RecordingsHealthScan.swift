import Foundation

/// Launch scan of `~/Movies/CoachCap` for recordings that never finalised, so a lost or damaged
/// check-in surfaces even when the coach never mentions it.
///
/// One warning event per file (at most 20 per launch), carrying ONLY: the class of problem, the
/// file's age in hours, its size in MB, and whether its folder is one of the app's own
/// `WC yyyy-MM-dd` week folders (a yes/no — never the folder's name). File names hold client
/// names and paths hold the macOS account name; neither is ever sent.
///
/// Each file is reported once. The list of what has been reported lives in UserDefaults under
/// `reportedBadRecordings`, in the same `<absolute path>#<size>` form the previous reporter
/// used, so no Mac re-reports old files after updating. That list is local only.
///
/// Runs only when telemetry is really sending (a DSN is configured, the coach has not opted
/// out, not an autotest run) — otherwise nothing is scanned, so nothing can be marked as
/// reported without having been sent.
enum RecordingsHealthScan {

    static let reportedKey = "reportedBadRecordings"
    static let maxEventsPerLaunch = 20

    private static let lock = NSLock()
    nonisolated(unsafe) private static var hasRun = false

    /// Starts the scan off the main thread. At most once per launch; later calls do nothing.
    /// `Telemetry.start()` already calls this, so no other call is needed.
    static func run() {
        guard Telemetry.isReporting, claimRun() else { return }
        DispatchQueue.global(qos: .utility).async { scan() }
    }

    private static func claimRun() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if hasRun { return false }
        hasRun = true
        return true
    }

    private struct Finding {
        let fileClass: RecordingFileClass
        let dedupeID: String
        let ageHours: Double
        let sizeMB: Double
        let inWeekFolder: Bool
        let modified: Date
    }

    private static func scan() {
        let scanStart = Date()
        let fm = FileManager.default
        let marker = SessionMarker.shared
        // Recordings an earlier session started and never finalised (local paths, never sent).
        let unfinalised = marker.unfinalisedPaths()
        let unfinalisedSet = Set(unfinalised.map(standardized))

        guard let dir = try? fm.url(for: .moviesDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: false)
            .appendingPathComponent("CoachCap", isDirectory: true),
              let walker = fm.enumerator(at: dir,
                    includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]) else {
            marker.clearUnfinalisedPaths(unfinalised)
            return
        }

        var reported = Set(UserDefaults.standard.stringArray(forKey: reportedKey) ?? [])
        let now = scanStart
        var findings: [Finding] = []

        for case let url as URL in walker where url.pathExtension.lowercased() == "mp4" {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            // A file touched after this scan began belongs to THIS session (a recording that has
            // just started is 0 bytes for a moment) — it is not a leftover.
            if let modified = values?.contentModificationDate, modified >= scanStart { continue }
            let size = values?.fileSize ?? 0
            let path = url.path
            guard let fileClass = RecordingsScanClassifier.classify(
                fileName: url.lastPathComponent,
                size: size,
                isUnfinalisedInFlight: unfinalisedSet.contains(standardized(path))) else { continue }

            let id = RecordingsScanClassifier.dedupeID(path: path, size: size)
            if reported.contains(id) { continue }

            let modified = values?.contentModificationDate ?? now
            let folder = url.deletingLastPathComponent().lastPathComponent
            findings.append(Finding(
                fileClass: fileClass,
                dedupeID: id,
                ageHours: max(0, now.timeIntervalSince(modified) / 3600),
                sizeMB: Double(size) / 1_000_000,
                inWeekFolder: RecordingsScanClassifier.isWeekFolderName(folder),
                modified: modified))
        }

        // Truncated recordings first (they are tied to a session that just ended badly), then
        // newest first, so the cap never hides the files that matter most.
        findings.sort { a, b in
            let aTruncated = a.fileClass == .truncated
            let bTruncated = b.fileClass == .truncated
            if aTruncated != bTruncated { return aTruncated }
            return a.modified > b.modified
        }

        let batch = findings.prefix(maxEventsPerLaunch)
        for finding in batch {
            Telemetry.captureWarning(
                eventName(for: finding.fileClass),
                fingerprint: ["recordings-scan", token(for: finding.fileClass)],
                ["file_class": .token(token(for: finding.fileClass)),
                 "age_hours": .double((finding.ageHours * 10).rounded() / 10),
                 "size_mb": .double((finding.sizeMB * 100).rounded() / 100),
                 "in_week_folder": .bool(finding.inWeekFolder)])
            reported.insert(finding.dedupeID)
        }

        // Mark as reported only once the capture calls have been made: this runs on the
        // telemetry queue behind them. (The SDK keeps events on disk while offline.)
        let newlyReported = Array(reported)
        let reportedSomething = !batch.isEmpty
        Telemetry.afterPendingCaptures {
            if reportedSomething {
                UserDefaults.standard.set(newlyReported, forKey: reportedKey)
            }
            marker.clearUnfinalisedPaths(unfinalised)
        }
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    // The class as compile-time constants (telemetry accepts nothing else).

    private static func token(for fileClass: RecordingFileClass) -> StaticString {
        switch fileClass {
        case .empty: return "empty"
        case .emptyUnfinished: return "empty_unfinished"
        case .unfinished: return "unfinished"
        case .truncated: return "truncated"
        case .workfileEmpty: return "workfile_empty"
        }
    }

    private static func eventName(for fileClass: RecordingFileClass) -> StaticString {
        switch fileClass {
        case .empty: return "empty recording found"
        case .emptyUnfinished: return "empty unfinished recording found"
        case .unfinished: return "unfinished recording found"
        case .truncated: return "truncated recording found"
        case .workfileEmpty: return "empty work file found"
        }
    }
}
