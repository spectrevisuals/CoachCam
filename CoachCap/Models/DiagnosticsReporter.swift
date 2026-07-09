import Foundation

/// Best-effort, privacy-safe error telemetry for the beta.
///
/// When a recording fails or is interrupted, this sends a short diagnostic line — app version,
/// macOS version, an anonymous device id, the error, and per-track sample counts — to an incoming
/// webhook, so failures reach the developer WITHOUT asking each tester to dig out a log file.
///
/// It sends NO recordings, NO client names, NO personal data — only the same diagnostic strings
/// already written to the local error log. It's a fire-and-forget POST that never blocks or
/// affects recording, and is a complete no-op until `webhookURL` is filled in.
enum DiagnosticsReporter {

    /// A Discord or Slack incoming-webhook URL. Empty string = reporting disabled.
    /// Discord: Server Settings → Integrations → Webhooks → New Webhook → Copy URL.
    /// Slack:   create an "Incoming Webhook" app and copy its URL.
    static let webhookURL = "https://discord.com/api/webhooks/1524772683475062834/3sS7nmaBMBdZna0T0tmQsDPQE_Au7Yw1_A8t5iWsLmOHEf0cAX89a3zfN06GugphsxGl"

    /// Lets a tester opt out via `defaults write <bundleid> shareDiagnostics -bool false`.
    /// Defaults ON for the beta.
    private static var enabled: Bool {
        UserDefaults.standard.object(forKey: "shareDiagnostics") as? Bool ?? true
    }

    static func report(_ summary: String, detail: String = "") {
        guard enabled, !webhookURL.isEmpty, let url = URL(string: webhookURL) else { return }

        let ver    = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build  = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let os     = ProcessInfo.processInfo.operatingSystemVersionString
        let device = String(DeviceIdentity.hardwareUUID.prefix(8))

        var text = "⚠️ CoachCam \(ver) (\(build)) · macOS \(os) · device \(device)\n\(summary)"
        if !detail.isEmpty { text += "\n\(detail)" }
        text = String(text.prefix(1800))   // Discord caps message content at 2000 chars

        // Discord reads "content", Slack reads "text" — send both so either webhook type works.
        let body: [String: String] = ["content": text, "text": text]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        req.timeoutInterval = 10
        URLSession.shared.dataTask(with: req).resume()   // fire-and-forget
    }

    /// On launch, scan ~/Movies/CoachCap for recordings that failed to finalise — leftover
    /// `.unfinished.mp4` files and 0-byte `.mp4` files — and report any NEW ones once. This
    /// surfaces corruptions even when the coach never messages about them.
    ///
    /// Privacy: filenames contain client names, so they are NEVER sent. Only the (date-named)
    /// containing folder, the file's date, its size, and whether it looks recoverable go out.
    /// Runs off the main thread; a no-op until `webhookURL` is set.
    static func scanRecordingsFolder() {
        guard enabled, !webhookURL.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { _scanRecordingsFolder() }
    }

    private static func _scanRecordingsFolder() {
        let fm = FileManager.default
        guard let dir = try? fm.url(for: .moviesDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: false)
            .appendingPathComponent("CoachCap", isDirectory: true),
              let walker = fm.enumerator(at: dir,
                    includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]) else { return }

        var reported = Set(UserDefaults.standard.stringArray(forKey: "reportedBadRecordings") ?? [])
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"
        var found: [String] = []

        for case let url as URL in walker where url.pathExtension.lowercased() == "mp4" {
            let name = url.lastPathComponent
            let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = vals?.fileSize ?? 0
            let unfinished = name.hasSuffix(".unfinished.mp4")
            let empty = size == 0
            guard unfinished || empty else { continue }

            let id = "\(url.path)#\(size)"          // dedupe on path+size so it's reported once
            if reported.contains(id) { continue }
            reported.insert(id)

            let when   = vals?.contentModificationDate.map { df.string(from: $0) } ?? "unknown date"
            let folder = url.deletingLastPathComponent().lastPathComponent   // "WC ####-##-##" (no name)
            let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            let verdict = empty ? "EMPTY (0 bytes — nothing captured, not recoverable)"
                                : "unfinished (\(sizeStr) — has data, likely recoverable)"
            found.append("• \(verdict) · \(folder) · \(when)")
        }

        UserDefaults.standard.set(Array(reported), forKey: "reportedBadRecordings")
        guard !found.isEmpty else { return }
        report("🟣 corrupt/unfinished recording(s) found on this Mac (\(found.count))",
               detail: found.prefix(20).joined(separator: "\n"))
    }
}
