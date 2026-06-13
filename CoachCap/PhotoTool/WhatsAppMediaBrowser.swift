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
    var fileSize: Int = 0
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
            // WhatsApp delivers HD photos as a second message (a higher-res copy of
            // the standard one sent moments earlier), so an 8-photo check-in lands as
            // 16 rows. Collapse those duplicate pairs before building thumbnails.
            let unique = Self.dedupHDDuplicates(rows)
            return unique.map { item -> WhatsAppMediaItem in
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
            SELECT mi.ZMEDIALOCALPATH, m.ZMESSAGEDATE + 978307200, mi.ZFILESIZE
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
            let size    = Int(sqlite3_column_int64(stmt, 2))
            let full    = (mediaBase as NSString).appendingPathComponent(relPath)
            guard FileManager.default.fileExists(atPath: full) else { continue }
            out.append(WhatsAppMediaItem(url: URL(fileURLWithPath: full),
                                         date: Date(timeIntervalSince1970: ts),
                                         fileSize: size))
        }
        return out
    }

    // MARK: HD-duplicate collapsing

    /// Removes WhatsApp's HD/standard duplicate pairs. WhatsApp sends an HD photo as a
    /// second message holding a higher-res copy of the standard one, so the same image
    /// arrives twice with different files. We match by a 256-bit perceptual hash and keep
    /// the larger (HD) copy. Threshold 7 sits safely between true twins (≤3) and distinct
    /// physique photos of the same client (≥11) measured on real check-in data.
    nonisolated static func dedupHDDuplicates(_ items: [WhatsAppMediaItem]) -> [WhatsAppMediaItem] {
        struct Kept { var item: WhatsAppMediaItem; let hash: [UInt64]? }
        var kept: [Kept] = []
        for item in items {
            let hash = perceptualHash(item.url)
            if let hash,
               let idx = kept.firstIndex(where: { $0.hash != nil && hammingDistance($0.hash!, hash) <= 7 }) {
                // Duplicate of an already-kept photo — keep whichever file is larger (HD).
                if item.fileSize > kept[idx].item.fileSize {
                    kept[idx] = Kept(item: item, hash: hash)
                }
            } else {
                kept.append(Kept(item: item, hash: hash))
            }
        }
        return kept.map { $0.item }
    }

    /// 256-bit dHash: downscale to a 17×16 luma grid and record, per row, whether each
    /// pixel is brighter than its right-hand neighbour (16×16 = 256 comparisons).
    ///
    /// We decode the full image and let CoreGraphics do a single high-quality downsample
    /// straight to the grid. Going via a small intermediate thumbnail (or `.low`
    /// interpolation) resamples the standard and HD copies inconsistently and pushes true
    /// twins past the match threshold — measured on real check-in data, the full/high path
    /// keeps twins ≤3 while distinct photos stay ≥11.
    // Hashing decodes the full image, so cache by path: the date list and the per-date
    // photo load both hash the same files, and a file's pixels never change.
    private static let hashCacheLock = NSLock()
    nonisolated(unsafe) private static var hashCache: [String: [UInt64]?] = [:]

    nonisolated static func perceptualHash(_ url: URL) -> [UInt64]? {
        let key = url.path
        hashCacheLock.lock()
        if let cached = hashCache[key] { hashCacheLock.unlock(); return cached }
        hashCacheLock.unlock()

        let result = computePerceptualHash(url)

        hashCacheLock.lock()
        hashCache[key] = result
        hashCacheLock.unlock()
        return result
    }

    nonisolated static func computePerceptualHash(_ url: URL) -> [UInt64]? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg  = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return nil }

        let w = 17, h = 16
        var pixels = [UInt8](repeating: 0, count: w * h)
        let gray = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: gray,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var bits = [UInt64](repeating: 0, count: 4) // 256 bits
        var k = 0
        for y in 0..<h {
            for x in 0..<(w - 1) {
                if pixels[y * w + x] > pixels[y * w + x + 1] {
                    bits[k >> 6] |= (UInt64(1) << UInt64(k & 63))
                }
                k += 1
            }
        }
        return bits
    }

    nonisolated static func hammingDistance(_ a: [UInt64], _ b: [UInt64]) -> Int {
        var d = 0
        for i in 0..<min(a.count, b.count) { d += (a[i] ^ b[i]).nonzeroBitCount }
        return d
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
