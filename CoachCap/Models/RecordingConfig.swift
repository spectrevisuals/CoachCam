import Foundation
import AVFoundation
import CoreGraphics

struct RecordingConfig {
    var outputURL: URL
    var videoSize: CGSize
    var frameRate: Int = 30
    var pipNormalizedRect: CGRect
    var selectedMicID: String?

    // Auto-selects bitrate so 2-5 min clips fit in WhatsApp's ~16 MB limit.
    static func videoBitrate(for size: CGSize) -> Int {
        switch size.width {
        case 1920...: return 4_000_000   // 1080p
        case 1280...: return 2_500_000   // 720p
        default:      return 1_500_000   // smaller
        }
    }

    static let audioBitrate = 128_000   // 128 kbps AAC

    // Generates ~/Movies/CoachCap/ClientName_YYYY-MM-DD[_n].mp4
    static func autoOutputURL(clientName: String) -> URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        let dir = movies.appendingPathComponent("CoachCap", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let dateStr = df.string(from: Date())

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
