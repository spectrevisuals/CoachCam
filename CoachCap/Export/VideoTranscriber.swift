import AVFoundation
import Foundation
import Speech

/// On-demand, ON-DEVICE transcription of a finished recording — powers "find in recording"
/// in the trim editor (type a phrase → jump to where it was said).
///
/// Deliberately on-device only (`requiresOnDeviceRecognition`): check-in audio is client
/// content and never leaves the Mac. Runs only when the coach asks (never automatically),
/// takes ~15–40 s for a 5-minute clip on Apple Silicon, and the word-timestamped result is
/// cached (keyed by filename + size) so every later search is instant.
enum VideoTranscriber {

    struct Word: Codable {
        let text: String
        let time: Double
        let duration: Double
    }

    enum TranscribeError: LocalizedError {
        case denied, unavailable, failed(String)
        var errorDescription: String? {
            switch self {
            case .denied:
                return "Speech recognition permission was declined — enable it in System Settings → Privacy & Security → Speech Recognition."
            case .unavailable:
                return "On-device transcription isn't available on this Mac (audio is never uploaded, so search needs the on-device engine)."
            case .failed(let m):
                return "Transcription failed — \(m)"
            }
        }
    }

    // MARK: Cache

    private static var cacheDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("CoachCam/transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cacheURL(for url: URL) -> URL {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        // "-v2": transcripts cached before the long-recording fix (utterance accumulation)
        // hold only the last utterance — the version bump forces a clean re-transcribe.
        let key = "\(url.deletingPathExtension().lastPathComponent)-\(size)-v2"
            .replacingOccurrences(of: "/", with: "_")
        return cacheDir.appendingPathComponent("\(key).json")
    }

    static func cachedTranscript(for url: URL) -> [Word]? {
        guard let data = try? Data(contentsOf: cacheURL(for: url)) else { return nil }
        return try? JSONDecoder().decode([Word].self, from: data)
    }

    // MARK: Transcribe

    static func transcribe(url: URL,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> [Word] {
        // Permission (system prompt on first use; NSSpeechRecognitionUsageDescription required).
        let status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard status == .authorized else { throw TranscribeError.denied }

        guard let recognizer = SFSpeechRecognizer(locale: Locale.current)
                ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw TranscribeError.unavailable
        }

        let duration = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true    // client audio NEVER leaves the Mac
        request.shouldReportPartialResults = true     // drives the progress bar
        if #available(macOS 13, *) { request.addsPunctuation = true }

        // The recognizer calls back repeatedly (partials) and can surface both a final result
        // AND an error — the flag guards the continuation against double-resume.
        //
        // CRITICAL: on-device recognition of long audio arrives as a series of UTTERANCES.
        // Each utterance completes in a callback whose `speechRecognitionMetadata` is non-nil
        // (absolute in-file timestamps, settled text), after which `bestTranscription` RESETS
        // and the next utterance's partials start from scratch (timestamps show 0.0 until that
        // utterance settles). The `isFinal` callback holds ONLY the last utterance — so the
        // words must be accumulated at every metadata callback, not read once at the end.
        // (Verified against a 131 s recording: 7 utterances; keeping only the final result
        // returned just the last 13 s of speech.)
        final class State: @unchecked Sendable {
            let lock = NSLock()
            var task: SFSpeechRecognitionTask?
            var finished = false
            var collected: [Word] = []
        }
        let state = State()

        let words: [Word] = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                state.task = recognizer.recognitionTask(with: request) { result, error in
                    state.lock.lock(); defer { state.lock.unlock() }
                    guard !state.finished else { return }
                    if let result {
                        // Progress: utterance-final callbacks carry absolute timestamps;
                        // mid-utterance partials report 0.0, so keep it monotonic via max().
                        if duration > 0, let last = result.bestTranscription.segments.last {
                            let reached = max(state.collected.last.map { $0.time + $0.duration } ?? 0,
                                              last.timestamp)
                            progress(min(1, reached / duration))
                        }
                        let utteranceSettled = result.speechRecognitionMetadata != nil
                        if utteranceSettled {
                            state.collected += result.bestTranscription.segments.map {
                                Word(text: $0.substring, time: $0.timestamp, duration: $0.duration)
                            }
                        }
                        if result.isFinal {
                            state.finished = true
                            if !utteranceSettled {   // final without metadata: don't drop the tail
                                state.collected += result.bestTranscription.segments.map {
                                    Word(text: $0.substring, time: $0.timestamp, duration: $0.duration)
                                }
                            }
                            cont.resume(returning: state.collected)
                        }
                    } else if let error {
                        state.finished = true
                        cont.resume(throwing: TranscribeError.failed(error.localizedDescription))
                    }
                }
            }
        } onCancel: {
            state.lock.lock(); state.task?.cancel(); state.lock.unlock()
        }

        if let data = try? JSONEncoder().encode(words) {
            try? data.write(to: cacheURL(for: url))
        }
        return words
    }

    // MARK: Search

    struct Match {
        let time: Double
        let snippet: String
    }

    /// Case/punctuation-insensitive phrase search. Each query token must match the word at
    /// that position (equal, or the word starts with it — so "record" finds "recording").
    /// Auto-export (the "save a transcript file with every recording" setting): transcribe
    /// on-device and write `<recording name>.txt` beside the clip, plus a copy into the
    /// backup folder when one is set — so a coach can point Claude/an AI at a folder of
    /// check-in transcripts (coach-owned storage; nothing ever uploaded by us).
    /// Fire-and-forget on a background task: failures log to the error file and never
    /// surface in the UI or touch the save path.
    /// Error sink — the app points this at RecordingSession.appendErrorLog at launch.
    /// A plain var (not a direct call) keeps this file free of app-target dependencies,
    /// since the unit-test target compiles it standalone for the search tests.
    nonisolated(unsafe) static var log: @Sendable (String) -> Void = { NSLog("%@", $0) }

    static func autoExport(for url: URL, backupFolder: String) {
        Task.detached(priority: .utility) {
            do {
                let words = try await transcribe(url: url) { _ in }
                let text = plainText(words)
                guard !text.isEmpty else { return }
                appendToWeeklyDoc(text, for: url, backupFolder: backupFolder)
            } catch {
                Self.log("transcript auto-save failed: \(error.localizedDescription)")
            }
        }
    }

    /// One rolling document per weekly recordings folder — "WC <Monday> transcripts.txt" —
    /// so by the end of the week every check-in's transcript is in a single file the coach
    /// can hand to Claude/an AI. Each recording appends one section (deduped on filename, so
    /// a re-save never doubles up); the whole doc is re-mirrored into the backup folder on
    /// every update. Lock-serialised: two transcriptions finishing together must not
    /// interleave their writes.
    private static let weeklyDocLock = NSLock()
    nonisolated private static func appendToWeeklyDoc(_ text: String, for url: URL, backupFolder: String) {
        weeklyDocLock.lock(); defer { weeklyDocLock.unlock() }
        let folder = url.deletingLastPathComponent()               // the "WC YYYY-MM-DD" folder
        let doc = folder.appendingPathComponent("\(folder.lastPathComponent) transcripts.txt")
        let marker = "════ \(url.lastPathComponent)"
        var contents = (try? String(contentsOf: doc, encoding: .utf8)) ?? ""
        guard !contents.contains(marker) else { return }           // already in the doc
        let df = DateFormatter(); df.dateFormat = "d MMM yyyy, HH:mm"
        contents += (contents.isEmpty ? "" : "\n\n")
            + "\(marker) · \(df.string(from: Date())) ════\n\n" + text + "\n"
        do {
            try contents.write(to: doc, atomically: true, encoding: .utf8)
            if !backupFolder.isEmpty {
                let dest = URL(fileURLWithPath: backupFolder).appendingPathComponent(doc.lastPathComponent)
                try? contents.write(to: dest, atomically: true, encoding: .utf8)
            }
        } catch {
            Self.log("transcript weekly doc write failed: \(error.localizedDescription)")
        }
    }

    /// Render a transcript as readable plain text for copy/paste (e.g. into an AI summariser).
    /// Words flow as prose; a speech gap over 2s starts a new paragraph, each opening with a
    /// [m:ss] marker so the coach (or the AI) can still reference moments in the clip.
    static func plainText(_ words: [Word]) -> String {
        guard !words.isEmpty else { return "" }
        func stamp(_ t: Double) -> String { String(format: "[%d:%02d]", Int(t) / 60, Int(t) % 60) }
        var paragraphs: [String] = []
        var current: [String] = []
        var paragraphStart = words[0].time
        var lastEnd = words[0].time
        for w in words {
            if w.time - lastEnd > 2.0, !current.isEmpty {
                paragraphs.append(stamp(paragraphStart) + " " + current.joined(separator: " "))
                current = []
                paragraphStart = w.time
            }
            current.append(w.text)
            lastEnd = w.time + w.duration
        }
        if !current.isEmpty { paragraphs.append(stamp(paragraphStart) + " " + current.joined(separator: " ")) }
        return paragraphs.joined(separator: "\n\n")
    }

    static func search(_ query: String, in words: [Word]) -> [Match] {
        func norm(_ s: String) -> String {
            s.lowercased().trimmingCharacters(in: .punctuationCharacters)
        }
        let tokens = query.split(separator: " ").map { norm(String($0)) }.filter { !$0.isEmpty }
        guard !tokens.isEmpty, words.count >= tokens.count else { return [] }
        var out: [Match] = []
        for i in 0...(words.count - tokens.count) {
            var ok = true
            for (j, tok) in tokens.enumerated() {
                let w = norm(words[i + j].text)
                if !(w == tok || w.hasPrefix(tok)) { ok = false; break }
            }
            guard ok else { continue }
            let lo = max(0, i - 4), hi = min(words.count - 1, i + tokens.count + 3)
            let snippet = words[lo...hi].map(\.text).joined(separator: " ")
            out.append(Match(time: words[i].time, snippet: "…\(snippet)…"))
        }
        return out
    }
}
