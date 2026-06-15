import Foundation
import CoreGraphics

/// Free-tier limits in ONE place so they can be retuned without hunting through code.
/// Free users get all three limits; paid users (LicenseManager.shared.isUnlocked) get none.
enum FreeTier {
    // 1. Recording length cap (seconds)
    static let maxRecordingSeconds = 120

    // 2. Recordings per calendar month
    static let maxRecordingsPerMonth = 10

    // 3. Watermark on before/after comparison photos
    static let watermarkText        = "CoachCam"
    static let watermarkOpacity:      CGFloat = 0.60   // 60% — strongly visible free-version mark
    static let watermarkAngleDegrees: CGFloat = -30
    /// Font size as a fraction of the image's longest edge (scales with image size).
    static let watermarkFontFraction: CGFloat = 0.045
}

/// Tracks how many recordings a free user has made this calendar month. Persisted in
/// UserDefaults so it survives restarts; resets automatically when the month rolls over.
enum RecordingQuota {
    private static let countKey = "freeRecordingCount"
    private static let monthKey = "freeRecordingMonth"   // "yyyy-MM"

    private static var currentMonth: String {
        let c = Calendar.current.dateComponents([.year, .month], from: Date())
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    /// Recordings used this month (0 once the month rolls over, even before any write).
    static func used() -> Int {
        guard UserDefaults.standard.string(forKey: monthKey) == currentMonth else { return 0 }
        return UserDefaults.standard.integer(forKey: countKey)
    }

    static func remaining() -> Int { max(0, FreeTier.maxRecordingsPerMonth - used()) }

    static func canRecord() -> Bool { remaining() > 0 }

    /// Count one completed recording (call only for free users, on successful save).
    static func recordOne() {
        let month = currentMonth
        var count = UserDefaults.standard.integer(forKey: countKey)
        if UserDefaults.standard.string(forKey: monthKey) != month {
            // New month — reset before counting.
            UserDefaults.standard.set(month, forKey: monthKey)
            count = 0
        }
        UserDefaults.standard.set(count + 1, forKey: countKey)
    }
}
