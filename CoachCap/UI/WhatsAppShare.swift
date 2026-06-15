import AppKit
import SwiftUI
import SQLite3

/// Hands a finished check-in VIDEO to WhatsApp desktop.
///
/// WhatsApp desktop provides **no macOS Share Extension** and no file URL scheme, so it can't
/// appear in the system share sheet and a video can't be attached programmatically. The only
/// reliable path is **drag-and-drop**: we open WhatsApp and reveal the (fully-written) video
/// selected in Finder, so the coach drags it straight into the chat. Clipboard paste of video
/// is unreliable and is deliberately not used.
enum WhatsAppShare {
    private static let bundleID = "net.whatsapp.WhatsApp"

    static func isWhatsAppInstalled() -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// Looks up a WhatsApp contact's phone number (E.164, no '+') from their display name,
    /// so we can deep-link straight to their chat. Returns nil if not found.
    static func phoneNumber(forContactName name: String) -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(WhatsAppMediaLoader.dbPath, &db,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }
        let sql = "SELECT ZCONTACTJID FROM ZWACHATSESSION WHERE ZPARTNERNAME = ? AND ZCONTACTJID LIKE '%@s.whatsapp.net' LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        let TR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, name, -1, TR)
        if sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) {
            // ZCONTACTJID is like "447932250828@s.whatsapp.net"
            return String(cString: c).components(separatedBy: "@").first
        }
        return nil
    }

    /// Opens WhatsApp (to the client's chat if we can resolve their number) and reveals the
    /// finished video in Finder so the coach can drag it straight into that chat.
    static func sendToWhatsApp(videoURL url: URL, clientName: String?) {
        // Don't hand off a half-written file. session.stop() awaits finishWriting, so by here
        // it's complete — but verify it exists and is non-empty.
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard FileManager.default.fileExists(atPath: url.path), size > 0 else {
            ExportManager.revealInFinder(url)
            return
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = false   // background, so it doesn't cover Finder

        // Open the client's specific chat if we can resolve their WhatsApp number…
        if let name = clientName?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
           let phone = phoneNumber(forContactName: name),
           let chatURL = URL(string: "whatsapp://send?phone=\(phone)") {
            NSWorkspace.shared.open(chatURL, configuration: config, completionHandler: nil)
        } else if let wa = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            // …otherwise just open WhatsApp.
            NSWorkspace.shared.openApplication(at: wa, configuration: config, completionHandler: nil)
        }

        // Reveal slightly after, frontmost, so Finder ends up on top of WhatsApp.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            ExportManager.revealInFinder(url)
            NSApp.deactivate()
        }
    }
}

/// "send to whatsapp" button — opens the client's WhatsApp chat + reveals the video in Finder.
struct WhatsAppShareButton: View {
    let url: URL
    var clientName: String?
    var body: some View {
        Button { WhatsAppShare.sendToWhatsApp(videoURL: url, clientName: clientName) } label: {
            HStack(spacing: 7) {
                Image(systemName: "paperplane.fill")
                Text("send to whatsapp")
            }
        }
        .buttonStyle(PrimaryButtonStyle(color: Color(hex: 0x25D366)))   // WhatsApp green
        .help("Opens the client's WhatsApp chat and reveals the video in Finder — drag it in.")
    }
}
