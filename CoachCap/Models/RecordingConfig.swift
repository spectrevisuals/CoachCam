import Foundation
import AVFoundation
import CoreGraphics

struct RecordingConfig {
    var outputURL: URL
    var videoSize: CGSize
    var frameRate: Int = 30
    var pipNormalizedRect: CGRect
    var selectedMicID: String?
    var displayID: CGDirectDisplayID?   // which monitor to capture; nil = primary
    var sourceRect: CGRect? = nil       // custom-area crop (display points, top-left origin); nil = whole display

    // Auto-selects bitrate so 2-5 min clips fit in WhatsApp's ~16 MB limit.
    static func videoBitrate(for size: CGSize) -> Int {
        switch size.width {
        case 1920...: return 4_000_000   // 1080p
        case 1280...: return 2_500_000   // 720p
        default:      return 1_500_000   // smaller
        }
    }

    static let audioBitrate = 128_000   // 128 kbps AAC

    // Generates ~/Movies/CoachCap/WC YYYY-MM-DD/ClientName_YYYY-MM-DD[_n].mp4
    // Recordings are grouped into a weekly "WC (week commencing) <Monday>" folder.
    static func autoOutputURL(clientName: String) -> URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        let now = Date()

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"

        // Monday of the current week = "week commencing" date.
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: now)     // 1 = Sun … 7 = Sat
        let daysSinceMonday = (weekday + 5) % 7              // Mon=0, Tue=1, … Sun=6
        let monday = cal.date(byAdding: .day, value: -daysSinceMonday, to: cal.startOfDay(for: now)) ?? now
        let weekFolder = "WC \(df.string(from: monday))"

        let dir = movies
            .appendingPathComponent("CoachCap", isDirectory: true)
            .appendingPathComponent(weekFolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let dateStr = df.string(from: now)

        let base = clientName.trimmingCharacters(in: .whitespaces).isEmpty
            ? "Recording"
            : clientName.trimmingCharacters(in: .whitespaces)
        let safeName = base.replacingOccurrences(of: "/", with: "-")

        var url = dir.appendingPathComponent("\(safeName)_\(dateStr)").appendingPathExtension("mp4")
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(safeName)_\(dateStr)_\(n)").appendingPathExtension("mp4")
            n += 1
        }
        return url
    }
}
