import AppKit
import SwiftUI

/// The coach's custom branding + backup preferences. Branding applies to what CLIENTS see —
/// the recorded video (logo watermark) and the exported before/after JPEGs (logo + brand
/// colours) — not the app's own UI, which stays CoachCam-styled.
///
/// Storage: the logo file lives in Application Support/CoachCam/ (copied on upload, so the
/// original can move/delete); colours + toggles + the backup folder path live in UserDefaults.
/// The app is unsandboxed, so a plain path is enough for the backup folder (no bookmarks).
@MainActor
final class BrandingStore: ObservableObject {
    static let shared = BrandingStore()

    // MARK: Published state

    @Published private(set) var logoImage: NSImage?
    @Published var primaryHex: String {
        didSet { UserDefaults.standard.set(primaryHex, forKey: Self.kPrimary) }
    }
    @Published var secondaryHex: String {
        didSet { UserDefaults.standard.set(secondaryHex, forKey: Self.kSecondary) }
    }
    /// Dedicated float-cam ring colour. Unset → falls back to primary, then CoachCam orange.
    @Published var ringHex: String {
        didSet { UserDefaults.standard.set(ringHex, forKey: Self.kRing) }
    }
    /// Burn the logo into recordings (only meaningful when a logo is set).
    @Published var showLogoOnRecordings: Bool {
        didSet { UserDefaults.standard.set(showLogoOnRecordings, forKey: Self.kShowOnVideo) }
    }
    /// Absolute path of the coach's backup folder ("" = backups off). Pointing this at an
    /// iCloud Drive / Google Drive / Dropbox folder gives Loom-style auto-upload with the
    /// coach's own storage and retention.
    @Published var backupFolderPath: String {
        didSet { UserDefaults.standard.set(backupFolderPath, forKey: Self.kBackupPath) }
    }

    // MARK: Keys / paths

    private static let kPrimary     = "brandPrimaryHex"
    private static let kSecondary   = "brandSecondaryHex"
    private static let kRing        = "brandRingHex"
    private static let kShowOnVideo = "brandShowLogoOnRecordings"
    private static let kBackupPath  = "backupFolderPath"

    private static var logoFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("CoachCam", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("brand-logo.png")
    }

    private init() {
        primaryHex   = UserDefaults.standard.string(forKey: Self.kPrimary) ?? ""
        secondaryHex = UserDefaults.standard.string(forKey: Self.kSecondary) ?? ""
        ringHex      = UserDefaults.standard.string(forKey: Self.kRing) ?? ""
        showLogoOnRecordings = UserDefaults.standard.object(forKey: Self.kShowOnVideo) as? Bool ?? true
        backupFolderPath = UserDefaults.standard.string(forKey: Self.kBackupPath) ?? ""
        logoImage = NSImage(contentsOf: Self.logoFileURL)
    }

    // MARK: Logo

    /// Copy the chosen image into Application Support as PNG (preserving alpha).
    func setLogo(from url: URL) {
        guard let img = NSImage(contentsOf: url),
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: Self.logoFileURL)
        logoImage = NSImage(contentsOf: Self.logoFileURL)
    }

    func removeLogo() {
        try? FileManager.default.removeItem(at: Self.logoFileURL)
        logoImage = nil
    }

    /// The logo as a CGImage for burning into recordings, or nil when disabled/unset.
    /// Snapshotted ONCE at recording start (passed via RecordingConfig) so nothing mutates
    /// on the encode queue mid-recording.
    func videoLogoCG() -> CGImage? {
        guard showLogoOnRecordings, let img = logoImage else { return nil }
        return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    // MARK: Colours

    var primaryColor: NSColor?   { NSColor(hexString: primaryHex) }
    var secondaryColor: NSColor? { NSColor(hexString: secondaryHex) }
    var ringColor: NSColor?      { NSColor(hexString: ringHex) }
    var hasBranding: Bool { logoImage != nil || primaryColor != nil || secondaryColor != nil }
}

// MARK: - Hex helpers

extension NSColor {
    convenience init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "" }
        return String(format: "%02X%02X%02X",
                      Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }
}

// MARK: - Recording backup

/// Copies a finished recording into the coach's backup folder (typically inside iCloud
/// Drive / Google Drive / Dropbox, whose sync clients then upload it). Runs entirely AFTER
/// finalize on a background queue — it never touches the recording pipeline.
enum BackupManager {
    /// Copies `url` into `folder` (collision-safe name). Calls `completion` on the main
    /// thread with the backed-up file's URL on success (so the UI can reveal THAT copy —
    /// right-clicking it in a Dropbox/Drive folder offers "Copy Link" for sending to
    /// clients), or a short user-facing failure string.
    static func backup(_ url: URL, toFolderPath folder: String,
                       completion: @escaping @MainActor (URL?, String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue else {
                DispatchQueue.main.async { completion(nil, "backup folder missing — check settings") }
                return
            }
            var dest = URL(fileURLWithPath: folder).appendingPathComponent(url.lastPathComponent)
            var n = 1
            let base = url.deletingPathExtension().lastPathComponent
            let ext  = url.pathExtension
            while fm.fileExists(atPath: dest.path) {
                dest = URL(fileURLWithPath: folder).appendingPathComponent("\(base)_\(n).\(ext)")
                n += 1
            }
            do {
                try fm.copyItem(at: url, to: dest)
                DispatchQueue.main.async { completion(dest, nil) }
            } catch {
                RecordingSession.appendErrorLog("backup copy failed: \(error.localizedDescription)")
                DispatchQueue.main.async { completion(nil, "backup failed — \(error.localizedDescription)") }
            }
        }
    }
}
