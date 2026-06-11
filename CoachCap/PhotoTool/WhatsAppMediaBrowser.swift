import AppKit
import SwiftUI
import SQLite3

// MARK: - Data

struct WAContact: Identifiable, Hashable {
    let id   = UUID()
    let name: String
    let photoCount: Int
    let lastActivity: Date
}

struct WhatsAppMediaItem: Identifiable {
    let id    = UUID()
    let url:   URL
    let date:  Date
    var thumb: NSImage?
}

// MARK: - Loader

@MainActor
final class WhatsAppMediaLoader: ObservableObject {
    @Published var contacts: [WAContact]          = []
    @Published var currentPhotos: [WhatsAppMediaItem] = []
    @Published var isLoadingContacts = true
    @Published var isLoadingPhotos   = false
    @Published var unavailable       = false

    nonisolated static let dbPath: String = {
        (("~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite") as NSString)
            .expandingTildeInPath
    }()

    nonisolated static let mediaBase: String = {
        (("~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message") as NSString)
            .expandingTildeInPath
    }()

    init() { Task { await loadContacts() } }

    func loadContacts() async {
        let result = await Task.detached(priority: .userInitiated) { Self.queryContacts() }.value
        if result == nil { unavailable = true }
        contacts = result ?? []
        isLoadingContacts = false
    }

    func loadPhotos(for contact: String, since: Date?) async {
        isLoadingPhotos = true
        currentPhotos = []
        let items = await Task.detached(priority: .userInitiated) {
            let rows = Self.queryPhotos(contact: contact, since: since)
            return rows.map { item -> WhatsAppMediaItem in
                var copy = item
                copy.thumb = Self.makeThumbnail(item.url)
                return copy
            }
        }.value
        currentPhotos = items
        isLoadingPhotos = false
    }

    // MARK: SQLite queries

    nonisolated static func queryContacts() -> [WAContact]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT cs.ZPARTNERNAME, COUNT(*) as cnt, MAX(m.ZMESSAGEDATE)
            FROM ZWAMESSAGE m
            JOIN ZWAMEDIAITEM mi ON mi.ZMESSAGE = m.Z_PK
            JOIN ZWACHATSESSION cs ON cs.Z_PK = m.ZCHATSESSION
            WHERE (mi.ZMEDIALOCALPATH LIKE '%.jpg'  OR mi.ZMEDIALOCALPATH LIKE '%.jpeg'
                OR mi.ZMEDIALOCALPATH LIKE '%.png'  OR mi.ZMEDIALOCALPATH LIKE '%.heic')
              AND m.ZISFROMME = 0
              AND cs.ZPARTNERNAME IS NOT NULL
            GROUP BY cs.ZPARTNERNAME
            ORDER BY MAX(m.ZMESSAGEDATE) DESC
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        var out: [WAContact] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cStr = sqlite3_column_text(stmt, 0) else { continue }
            let name  = String(cString: cStr)
            let count = Int(sqlite3_column_int(stmt, 1))
            let ts    = sqlite3_column_double(stmt, 2) + 978307200
            out.append(WAContact(name: name, photoCount: count, lastActivity: Date(timeIntervalSince1970: ts)))
        }
        return out
    }

    nonisolated static func queryPhotos(contact: String, since: Date?) -> [WhatsAppMediaItem] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }

        let sinceTs = (since?.timeIntervalSince1970 ?? 0) - 978307200

        let sql = """
            SELECT mi.ZMEDIALOCALPATH, m.ZMESSAGEDATE + 978307200
            FROM ZWAMESSAGE m
            JOIN ZWAMEDIAITEM mi ON mi.ZMESSAGE = m.Z_PK
            JOIN ZWACHATSESSION cs ON cs.Z_PK = m.ZCHATSESSION
            WHERE cs.ZPARTNERNAME = ?
              AND m.ZISFROMME = 0
              AND m.ZMESSAGEDATE >= ?
              AND (mi.ZMEDIALOCALPATH LIKE '%.jpg'  OR mi.ZMEDIALOCALPATH LIKE '%.jpeg'
                OR mi.ZMEDIALOCALPATH LIKE '%.png'  OR mi.ZMEDIALOCALPATH LIKE '%.heic')
            ORDER BY m.ZMESSAGEDATE DESC
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, contact, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, sinceTs)

        var out: [WhatsAppMediaItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cStr = sqlite3_column_text(stmt, 0) else { continue }
            let relPath = String(cString: cStr)
            let ts      = sqlite3_column_double(stmt, 1)
            let full    = (mediaBase as NSString).appendingPathComponent(relPath)
            guard FileManager.default.fileExists(atPath: full) else { continue }
            out.append(WhatsAppMediaItem(url: URL(fileURLWithPath: full),
                                         date: Date(timeIntervalSince1970: ts)))
        }
        return out
    }

    nonisolated static func makeThumbnail(_ url: URL, maxPx: CGFloat = 200) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPx,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

// MARK: - Browser View

struct WhatsAppMediaBrowser: View {
    let onAssign: (NSImage, AssignSlot) -> Void
    enum AssignSlot { case lastWeek, thisWeek }

    @StateObject private var loader = WhatsAppMediaLoader()
    @State private var selectedContact: String?   = nil
    @State private var dateRange: DateRangeOption = .lastMonth

    enum DateRangeOption: String, CaseIterable {
        case lastTwoWeeks = "Last 2 weeks"
        case lastMonth    = "Last month"
        case last3Months  = "Last 3 months"
        case last6Months  = "Last 6 months"
        case allTime      = "All time"

        var cutoffDate: Date? {
            let days: Double?
            switch self {
            case .lastTwoWeeks: days = 14
            case .lastMonth:    days = 30
            case .last3Months:  days = 90
            case .last6Months:  days = 180
            case .allTime:      days = nil
            }
            return days.map { Date().addingTimeInterval(-$0 * 86400) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            photoArea
        }
    }

    // MARK: Filter bar

    private var filterBar: some View {
        HStack(spacing: 10) {
            // Contact picker
            if loader.isLoadingContacts {
                ProgressView().scaleEffect(0.7)
            } else if loader.unavailable {
                Label("WhatsApp not found", systemImage: "message.fill")
                    .foregroundColor(.secondary).font(.caption)
            } else {
                Picker("Contact", selection: $selectedContact) {
                    Text("Select client…").tag(String?.none)
                    ForEach(loader.contacts) { c in
                        Text("\(c.name)  (\(c.photoCount))")
                            .tag(Optional(c.name))
                    }
                }
                .labelsHidden()
                .frame(width: 220)
                .onChange(of: selectedContact) { _, contact in
                    if let contact {
                        Task { await loader.loadPhotos(for: contact, since: dateRange.cutoffDate) }
                    }
                }
            }

            // Date range
            Picker("Range", selection: $dateRange) {
                ForEach(DateRangeOption.allCases, id: \.self) {
                    Text($0.rawValue).tag($0)
                }
            }
            .labelsHidden()
            .frame(width: 130)
            .onChange(of: dateRange) { _, range in
                if let contact = selectedContact {
                    Task { await loader.loadPhotos(for: contact, since: range.cutoffDate) }
                }
            }

            if !loader.currentPhotos.isEmpty {
                Text("\(loader.currentPhotos.count) photo\(loader.currentPhotos.count == 1 ? "" : "s")")
                    .foregroundColor(.secondary).font(.caption)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: Photo area

    @ViewBuilder
    private var photoArea: some View {
        if loader.isLoadingPhotos {
            ProgressView("Loading photos…")
                .frame(maxWidth: .infinity).frame(height: 108)
        } else if selectedContact == nil {
            Text("Select a client above to see their photos")
                .foregroundColor(.secondary).font(.caption)
                .frame(maxWidth: .infinity).frame(height: 108)
        } else if loader.currentPhotos.isEmpty {
            Text("No photos in this date range")
                .foregroundColor(.secondary).font(.caption)
                .frame(maxWidth: .infinity).frame(height: 108)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(loader.currentPhotos) { item in
                        WAThumbView(item: item, onAssign: onAssign)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .frame(height: 108)
        }
    }
}

// MARK: - Thumbnail

private struct WAThumbView: View {
    let item: WhatsAppMediaItem
    let onAssign: (NSImage, WhatsAppMediaBrowser.AssignSlot) -> Void
    @State private var isHovered = false

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM"; return f
    }()

    var body: some View {
        ZStack(alignment: .bottom) {
            // Image
            Group {
                if let t = item.thumb {
                    Image(nsImage: t).resizable().scaledToFill()
                } else {
                    Color(NSColor.controlColor)
                        .overlay(ProgressView().scaleEffect(0.6))
                }
            }
            .frame(width: 72, height: 90).clipped()

            // Date badge (always visible)
            Text(Self.dateFmt.string(from: item.date))
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(Color.black.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .padding(.bottom, 4)
                .opacity(isHovered ? 0 : 1)

            // LW / TW buttons on hover
            if isHovered {
                HStack(spacing: 3) {
                    assignBtn("LW", color: .blue,  slot: .lastWeek)
                    assignBtn("TW", color: .green, slot: .thisWeek)
                }
                .padding(.bottom, 4)
                .transition(.opacity)
            }
        }
        .frame(width: 72, height: 90)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.1), value: isHovered)
    }

    private func assignBtn(_ label: String, color: Color, slot: WhatsAppMediaBrowser.AssignSlot) -> some View {
        Button(label) {
            Task.detached(priority: .userInitiated) {
                let img = NSImage(contentsOf: item.url)
                await MainActor.run { if let img { onAssign(img, slot) } }
            }
        }
        .font(.system(size: 10, weight: .bold))
        .foregroundColor(.white)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(color.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .buttonStyle(.plain)
    }
}
