import Foundation

/// Last line of defence for text that the crash-reporting SDK collects BY ITSELF — exception
/// reasons, crash-info messages, the file-system paths of loaded binaries. CoachCam's own
/// telemetry calls never carry free text (see `Telemetry`); this scrubber exists for the strings
/// we do not author.
///
/// Why it matters: coaches record client check-ins. Recording file names contain client names
/// (`Jane Doe_2026-11-21.mp4`) and every path under the home folder contains the macOS account
/// name. None of that may leave the Mac.
///
/// What it does to a piece of text:
///  1. the home folder, and any `/Users/<name>` prefix, becomes `/Users/<redacted>`;
///  2. anything below the app's own data folders (`Movies/CoachCap`, `Pictures/CoachCap`,
///     `Library/Application Support/CoachCam`, WhatsApp's containers) is cut back to that folder;
///  3. anything below an external volume or a cloud-storage mount (`/Volumes/<name>`,
///     `Library/CloudStorage/<account>`) is cut back to `/Volumes/<redacted>` /
///     `Library/CloudStorage/<redacted>` (volume names and cloud accounts identify people);
///  4. any OTHER path below the home folder is cut back to `/Users/<redacted>/<path>` —
///     folders there are often named after clients (`Documents/Clients/Jane Doe/…`), and a
///     file name can have any extension. One exception: a source file (`….swift`, `.m`, …)
///     keeps its name, `/Users/<redacted>/<path>/RecordingSession.swift:820: Fatal error: …`,
///     because that path is the build machine's and the message after it is the crash reason;
///  5. for any other path (outside the home folder), a last component with a media/document
///     extension becomes `<file>.<ext>`;
///  6. a stand-alone recording-style name (`…_YYYY-MM-DD[_n]` followed by any run of
///     `.unfinished`, `.flat`, `_edited`, `_edited_n`, then `.mp4`) becomes `<recording>.mp4`,
///     redacted back to the previous path separator, quote, colon, `=` or start of line — so
///     names with spaces go too;
///  7. a quoted file name with a media/document extension (the way Cocoa error messages name
///     files: `“Jane.mov” couldn’t be opened`) becomes `“<file>.mov”`.
///
/// What it leaves alone: hex addresses, UUIDs, module names and symbol names (symbolication
/// must keep working), and any string with no path or recording name in it.
///
/// When a path's end is ambiguous (free text with spaces), the scrubber deliberately removes
/// too much rather than too little.
///
/// Foundation-only on purpose: this file is also compiled into the unit-test target
/// (`Tests/TelemetryScrubberTests.swift`). It must never import the Sentry module.
enum TelemetryScrubber {

    static let redactedUser = "/Users/<redacted>"

    /// Strings longer than this are cut before scrubbing, which bounds the work done per event.
    static let maxLength = 8_192

    // MARK: - Free text

    /// Scrubs one piece of free text. Safe to call from any thread.
    static func scrub(_ text: String, homeDirectory: String = NSHomeDirectory()) -> String {
        // Fast path: nothing that could be a path or a file name.
        guard text.contains("/") || text.contains(".") else { return text }

        var s = text
        if s.utf16.count > maxLength {
            s = String(s.prefix(maxLength)) + "…"
        }

        if s.contains("/") {
            s = redactHome(in: s, homeDirectory: homeDirectory)
            s = replace(usersPrefix, in: s, with: redactedUser)
            s = replace(appContainers, in: s, with: "$1")
            s = replace(externalRoots, in: s, with: "$1/<redacted>")
            if s.contains(redactedUser + "/") {
                s = replace(homeSourceFile, in: s, with: "$1/<path>/$2")
                s = replace(otherHomePath, in: s, with: "$1/<path>")
            }
            s = redactFileNames(in: s)
        }
        s = redactRecordingNames(in: s)
        s = replace(quotedFileName, in: s, with: "$1<file>.$2$3")
        return s
    }

    // MARK: - Whole-string paths of loaded binaries

    /// Scrubs a string that is KNOWN to be one complete path of a loaded binary (a stack frame's
    /// `package`, a debug image's `code_file`). Only the account name, the volume name and the
    /// cloud-account folder are replaced; the rest of the path — in particular the binary's own
    /// name — is kept, because crash grouping and the "in app" marker use it.
    static func scrubImagePath(_ path: String, homeDirectory: String = NSHomeDirectory()) -> String {
        guard path.hasPrefix("/") else { return scrub(path, homeDirectory: homeDirectory) }

        var p = path
        if isUsableHome(homeDirectory), !homeDirectory.hasPrefix("/Users/") {
            if p == homeDirectory {
                return redactedUser
            }
            if p.hasPrefix(homeDirectory + "/") {
                p = redactedUser + p.dropFirst(homeDirectory.count)
            }
        }

        var parts = p.components(separatedBy: "/")   // parts[0] is "" (leading slash)
        var index = 1
        while index < parts.count - 1 {
            let part = parts[index]
            let redactNext = part == "Users"
                || part == "CloudStorage"
                || (part == "Volumes" && index == 1)
            if redactNext, !parts[index + 1].isEmpty {
                parts[index + 1] = "<redacted>"
                index += 1
            }
            index += 1
        }
        return parts.joined(separator: "/")
    }

    // MARK: - Structured values

    /// Scrubs every string inside a JSON-like value (dictionaries and arrays, nested to any
    /// depth). Numbers, booleans, dates and null are returned unchanged. Dictionary keys are
    /// left alone: they are written in code, never produced at run time.
    static func scrubValue(_ value: Any, homeDirectory: String = NSHomeDirectory()) -> Any {
        if let string = value as? String {
            return scrub(string, homeDirectory: homeDirectory)
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues { scrubValue($0, homeDirectory: homeDirectory) }
        }
        if let array = value as? [Any] {
            return array.map { scrubValue($0, homeDirectory: homeDirectory) }
        }
        return value
    }

    // MARK: - Error domains

    /// An error domain reduced to `[A-Za-z0-9._-]`, at most 80 characters. Domains are normally
    /// reverse-DNS constants (`AVFoundationErrorDomain`, `NSCocoaErrorDomain`), but a library is
    /// free to put anything there, so nothing else is let through.
    static func sanitizedErrorDomain(_ domain: String, homeDirectory: String = NSHomeDirectory()) -> String {
        var out = String.UnicodeScalarView()
        // Scrubbed first, in case a library ever builds a domain out of a path.
        for scalar in scrub(domain, homeDirectory: homeDirectory).unicodeScalars {
            guard out.count < 80 else { break }
            let v = scalar.value
            let allowed = (v >= 48 && v <= 57)        // 0-9
                || (v >= 65 && v <= 90)               // A-Z
                || (v >= 97 && v <= 122)              // a-z
                || v == 46 || v == 95 || v == 45      // . _ -
            if allowed { out.append(scalar) }
        }
        return out.isEmpty ? "unknown" : String(out)
    }

    // MARK: - Rules

    /// Characters that can never be part of a path in the text we see: line breaks, double
    /// quotes (straight and curly), braces and the pipe. Commas, apostrophes, brackets and
    /// spaces are NOT in this set — file names contain them.
    private static let stop = "\\n\\r\"“”{}|"

    /// Where a path that runs through free text is taken to end: end of text, one of the `stop`
    /// characters, or the `, Key=` separator of an NSError `UserInfo={…}` dump.
    private static let pathEnd = "(?=$|[\(stop)]|,\\s+[A-Za-z_][A-Za-z0-9_]*=)"

    /// `/Users/<name>` (also percent-encoded). `<redacted>` itself is skipped.
    private static let usersPrefix = regex("/Users/(?!<redacted>)[^/\\s\"'“”<>,;:)}\\]]+")

    /// The app's own data folders and WhatsApp's containers, with everything below them.
    private static let appContainers = regex(
        "(/Movies/CoachCap"
        + "|/Pictures/CoachCap"
        + "|/Library/Application(?: |%20)Support/CoachCam"
        + "|/Library/(?:Group(?: |%20))?Containers/[^/,\(stop)]*[Ww]hats[Aa]pp[^/,\(stop)]*)"
        + "(?:/[^\(stop)]*?)?" + pathEnd)

    /// External volumes and cloud-storage mounts, with everything below them.
    private static let externalRoots = regex(
        "(/Volumes|/Library/CloudStorage)/[^\(stop)]*?" + pathEnd)

    /// What may stay visible directly below `/Users/<redacted>/` once the two rules above have
    /// run: the app's own data folders, WhatsApp's containers and a cloud-storage mount (its
    /// account already redacted).
    private static let keptHomeRoots =
        "(?:Movies/CoachCap"
        + "|Pictures/CoachCap"
        + "|Library/Application(?: |%20)Support/CoachCam"
        + "|Library/(?:Group(?: |%20))?Containers/[^/,\(stop)]*[Ww]hats[Aa]pp[^/,\(stop)]*"
        + "|Library/CloudStorage/<redacted>)"

    /// A source file below the home folder, as in a Swift or Objective-C trap message
    /// (`/Users/<name>/…/RecordingSession.swift:820: Fatal error: …`). That path is the build
    /// machine's, not the coach's. Its folders go; the file name stays so the message reads.
    private static let homeSourceFile = regex(
        "(/Users/<redacted>)/(?:[^/\(stop)]+/)*?"
        + "([^/\\s\(stop)]+\\.(?:swift|mm?|c|cc|cpp|hpp|h))(?![A-Za-z0-9/])")

    /// Any other path below the home folder, to the end of the path: everything after
    /// `/Users/<redacted>/` unless it is exactly one of `keptHomeRoots` (a root followed by
    /// more path — `Movies/CoachCap Old/Jane Doe/…` — is not "exactly", and goes).
    private static let otherHomePath = regex(
        "(/Users/<redacted>)/(?!<path>|" + keptHomeRoots + "(?=[^/\(stop)]*?" + pathEnd + "))"
        + "[^\(stop)]*?" + pathEnd)

    /// A media/document extension at the end of a path component.
    private static let fileExtension = regex(
        "\\.(mp4|mov|m4a|wav|jpe?g|png|heic|txt|json|sqlite|db|plist)(?![A-Za-z0-9])",
        options: [.caseInsensitive])

    /// The tail every CoachCam recording name ends with. The suffix group repeats: editing an
    /// edited copy gives `…_edited_edited.mp4`, `…_edited_2_edited.mp4`, and so on.
    private static let recordingSuffix = regex(
        "_\\d{4}-\\d{2}-\\d{2}(?:_\\d+)?(?:\\.unfinished|\\.flat|_edited(?:_\\d+)?)*\\.mp4",
        options: [.caseInsensitive])

    /// A file name with a media/document extension between double quotes (straight or curly).
    /// Names the earlier rules already replaced are skipped.
    private static let quotedFileName = regex(
        "([“\"])(?!<recording>|<file>)[^“”\"\\n\\r/]+?"
        + "\\.(mp4|mov|m4a|wav|jpe?g|png|heic|txt|json|sqlite|db|plist)([”\"])",
        options: [.caseInsensitive])

    private static let stopCharacters: Set<unichar> = Set("\n\r\"“”{}|".utf16)
    private static let nameBoundaries: Set<unichar> = Set("/\n\r\"“”:=".utf16)
    private static let slash: unichar = 0x2F

    // MARK: - Implementation

    private static func regex(_ pattern: String,
                              options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        // The patterns are constants; `try?` only keeps a typo from ever crashing the app.
        try? NSRegularExpression(pattern: pattern, options: options)
    }

    private static func replace(_ regex: NSRegularExpression?, in text: String,
                                with template: String) -> String {
        guard let regex else { return text }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, options: [], range: range,
                                              withTemplate: template)
    }

    private static func isUsableHome(_ home: String) -> Bool {
        home.hasPrefix("/") && home.count > 1
    }

    /// Replaces the real home folder (which may contain spaces, or live outside `/Users`), in
    /// both its plain and its percent-encoded (file URL) spelling.
    private static func redactHome(in text: String, homeDirectory: String) -> String {
        guard isUsableHome(homeDirectory) else { return text }
        var spellings = [homeDirectory]
        if let encoded = homeDirectory.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           encoded != homeDirectory {
            spellings.append(encoded)
        }
        var s = text
        for spelling in spellings where s.contains(spelling) {
            // Only when the match ends at a path boundary: `/Users/jake` must not eat the
            // start of `/Users/jakeb`.
            let pattern = NSRegularExpression.escapedPattern(for: spelling)
                + "(?=$|[/\\s\"'“”,;:)}\\]])"
            s = replace(regex(pattern), in: s, with: redactedUser)
        }
        return s
    }

    /// Rule 5: `…/<anything>.<media extension>` → `…/<file>.<ext>`. Works backwards from each
    /// extension to the previous `/`; if a `stop` character or the start of the text comes
    /// first, the name is not part of a path and is left for the recording-name rule.
    private static func redactFileNames(in text: String) -> String {
        guard let fileExtension else { return text }
        let ns = text as NSString
        let matches = fileExtension.matches(in: text, options: [],
                                            range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        let out = NSMutableString(string: text)
        // Right to left, so the ranges of earlier matches stay valid. A match that falls inside
        // a name that was already replaced (`notes.txt.mp4` has two extensions) is skipped.
        var replacedFrom = ns.length
        for match in matches.reversed() {
            let dot = match.range.location            // index of the "." before the extension
            guard dot < replacedFrom else { continue }
            var start = dot
            var foundSlash = false
            while start > 0 {
                let c = ns.character(at: start - 1)
                if c == slash { foundSlash = true; break }
                if stopCharacters.contains(c) { break }
                start -= 1
            }
            let nameLength = dot - start
            guard foundSlash, nameLength > 0, start + nameLength <= out.length else { continue }
            out.replaceCharacters(in: NSRange(location: start, length: nameLength), with: "<file>")
            replacedFrom = start
        }
        return out as String
    }

    /// Rule 6: a stand-alone `…_YYYY-MM-DD[…].mp4` name → `<recording>.mp4`, redacted back to
    /// the previous separator, quote, colon, `=` or start of line. Leading spaces are kept so
    /// the surrounding sentence still reads.
    private static func redactRecordingNames(in text: String) -> String {
        guard let recordingSuffix,
              text.range(of: ".mp4", options: .caseInsensitive) != nil else { return text }
        let ns = text as NSString
        let matches = recordingSuffix.matches(in: text, options: [],
                                              range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        let space: unichar = 0x20
        let tab: unichar = 0x09
        let out = NSMutableString(string: text)
        // Right to left, so earlier ranges stay valid. A match that falls inside a range that
        // was already replaced (two names with no boundary between them) is skipped.
        var replacedFrom = ns.length
        for match in matches.reversed() {
            let end = match.range.location + match.range.length
            guard end <= replacedFrom else { continue }
            var start = match.range.location
            while start > 0, !nameBoundaries.contains(ns.character(at: start - 1)) {
                start -= 1
            }
            while start < match.range.location,
                  ns.character(at: start) == space || ns.character(at: start) == tab {
                start += 1
            }
            guard end <= out.length else { continue }
            out.replaceCharacters(in: NSRange(location: start, length: end - start),
                                  with: "<recording>.mp4")
            replacedFrom = start
        }
        return out as String
    }
}

// MARK: - DSN shape

/// Shape check for a Sentry DSN (the address events are sent to). Telemetry only starts when
/// the value baked into Info.plist looks like `https://<key>@<host>/<project id>`; an empty or
/// malformed value means "telemetry does not exist". `Scripts/set_sentry_dsn.sh` applies the
/// same rule before it writes the value.
enum TelemetryDSN {

    private static let shape = try? NSRegularExpression(
        pattern: "^https://[A-Za-z0-9]+(?::[A-Za-z0-9]+)?@[A-Za-z0-9.-]+(?::[0-9]+)?"
            + "(?:/[A-Za-z0-9._-]+)*/[0-9]+$")

    /// The trimmed DSN when it is well formed, otherwise nil.
    static func wellFormed(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let dsn = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dsn.isEmpty, dsn.count <= 512, let shape else { return nil }
        let range = NSRange(location: 0, length: (dsn as NSString).length)
        return shape.firstMatch(in: dsn, options: [], range: range) != nil ? dsn : nil
    }
}
