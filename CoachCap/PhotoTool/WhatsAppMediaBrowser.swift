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

// WhatsAppMediaItem and the perceptual-hash matching / thumbnailing live in PhotoMatching.swift
// (dependency-free, so they can be unit-tested). WhatsAppMediaLoader forwards to them below.

// MARK: - Loader

@MainActor
final class WhatsAppMediaLoader: ObservableObject {
    @Published var contacts: [WAContact]          = []
    @Published var currentPhotos: [WhatsAppMediaItem] = []
    @Published var isLoadingContacts = true
    @Published var isLoadingPhotos   = false
    @Published var unavailable       = false

    /// The active WhatsApp group container. The consumer app and WhatsApp Business use
    /// different containers (`WhatsApp.shared` vs `WhatsAppSMB.shared`); a coach who switches
    /// account types may end up with both on disk — including an EMPTY leftover one, which a
    /// pure file-date heuristic can wrongly pick (the live DB's writes land in `-wal`, so its
    /// main .sqlite can look older than a dead install's). `queryContacts()` therefore probes
    /// every candidate for actual rows and locks `containerBase` to the one with data.
    nonisolated static let candidateBases: [String] = {
        let root = ("~/Library/Group Containers" as NSString).expandingTildeInPath
        return ["group.net.whatsapp.WhatsApp.shared", "group.net.whatsapp.WhatsAppSMB.shared"]
            .map { "\(root)/\($0)" }
    }()

    /// Last write across the DB and its WAL sidecar — the honest "is this container live" signal.
    nonisolated static func lastWrite(_ base: String) -> Date {
        ["ChatStorage.sqlite", "ChatStorage.sqlite-wal"]
            .compactMap { (try? FileManager.default.attributesOfItem(atPath: "\(base)/\($0)"))?[.modificationDate] as? Date }
            .max() ?? .distantPast
    }

    nonisolated(unsafe) static var containerBase: String =
        candidateBases.max { lastWrite($0) < lastWrite($1) } ?? candidateBases[0]

    nonisolated static var dbPath: String { "\(containerBase)/ChatStorage.sqlite" }
    nonisolated static var mediaBase: String { "\(containerBase)/Message" }

    init() { Task { await loadContacts() } }

    func loadContacts() async {
        let result = await Task.detached(priority: .userInitiated) { Self.queryContacts() }.value
        if let result {
            contacts = result
            unavailable = false
        } else if contacts.isEmpty {
            // Only flag unavailable on a cold failure — a transient nil on a refresh
            // (e.g. the DB briefly locked) shouldn't wipe an already-loaded list.
            unavailable = true
        }
        isLoadingContacts = false
    }

    /// Re-queries the WhatsApp DB to pick up photos that have arrived since the app launched
    /// (or since the last look). `loadContacts` refreshes the picker counts; the selected
    /// contact's grid is reloaded quietly so it doesn't flash empty under the coach.
    func refresh(selectedContact: String?, since: Date?) async {
        await loadContacts()
        if let contact = selectedContact {
            await loadPhotos(for: contact, since: since, quiet: true)
        }
    }

    func loadPhotos(for contact: String, since: Date?, quiet: Bool = false) async {
        if !quiet {
            isLoadingPhotos = true
            currentPhotos = []
        }
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

    /// Probe every WhatsApp container on this Mac and use the freshest one that actually has
    /// client rows — an empty leftover install (e.g. consumer WhatsApp beside WhatsApp Business)
    /// can therefore never shadow the live app's data. Returns nil only when NO container could
    /// be read at all (missing or blocked by Full Disk Access) → the "WhatsApp not found" state.
    nonisolated(unsafe) private static var lastDiag = ""
    nonisolated static func queryContacts() -> [WAContact]? {
        var readable = false
        var best: (base: String, rows: [WAContact])? = nil
        var diag: [String] = []
        for base in candidateBases.sorted(by: { lastWrite($0) > lastWrite($1) }) {
            let name = base.hasSuffix("SMB.shared") ? "business" : "consumer"
            guard let rows = queryContacts(at: "\(base)/ChatStorage.sqlite") else {
                let exists = FileManager.default.fileExists(atPath: "\(base)/ChatStorage.sqlite")
                diag.append("\(name)=\(exists ? "unreadable" : "absent")")
                continue
            }
            readable = true
            diag.append("\(name)=\(rows.count) clients")
            if best == nil, !rows.isEmpty { best = (base, rows) }   // freshest-with-data wins
        }
        // Log the scan result, but only when it's a problem state or it changed — not every refresh.
        let summary = "whatsapp scan: \(diag.joined(separator: ", ")) → using \((best?.base ?? containerBase).hasSuffix("SMB.shared") ? "business" : "consumer")"
        if summary != lastDiag, best == nil || !readable {
            lastDiag = summary
            RecordingSession.appendErrorLog(summary)
        }
        if let best {
            containerBase = best.base      // photos + thumbnails must resolve from the same container
            return best.rows
        }
        return readable ? [] : nil
    }

    nonisolated static func queryContacts(at dbPath: String) -> [WAContact]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }

        // Only clients who've sent at least one photo (the join + LIKE filter), but ordered
        // by the chat's most recent message of ANY kind (ZLASTMESSAGEDATE) so the list
        // mirrors WhatsApp's own chat order — whoever you last spoke to is at the top.
        let sql = """
            SELECT cs.ZPARTNERNAME, COUNT(*) as cnt, MAX(cs.ZLASTMESSAGEDATE)
            FROM ZWAMESSAGE m
            JOIN ZWAMEDIAITEM mi ON mi.ZMESSAGE = m.Z_PK
            JOIN ZWACHATSESSION cs ON cs.Z_PK = m.ZCHATSESSION
            WHERE (mi.ZMEDIALOCALPATH LIKE '%.jpg'  OR mi.ZMEDIALOCALPATH LIKE '%.jpeg'
                OR mi.ZMEDIALOCALPATH LIKE '%.png'  OR mi.ZMEDIALOCALPATH LIKE '%.heic')
              AND m.ZISFROMME = 0
              AND cs.ZPARTNERNAME IS NOT NULL
            GROUP BY cs.ZPARTNERNAME
            ORDER BY MAX(cs.ZLASTMESSAGEDATE) DESC
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

    // MARK: HD-duplicate collapsing (forwards to PhotoMatching — see PhotoMatching.swift)

    nonisolated static func dedupHDDuplicates(_ items: [WhatsAppMediaItem]) -> [WhatsAppMediaItem] {
        PhotoMatching.dedupHDDuplicates(items)
    }

    nonisolated static func makeThumbnail(_ url: URL, maxPx: CGFloat = 200) -> NSImage? {
        PhotoMatching.makeThumbnail(url, maxPx: maxPx)
    }
}

// MARK: - Browser View

struct WhatsAppMediaBrowser: View {
    let onAssign: (NSImage, AssignSlot) -> Void
    enum AssignSlot { case lastWeek, thisWeek }

    @EnvironmentObject var appState: AppState
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
        // New check-in photos land in WhatsApp while CoachCam stays open. Re-query whenever
        // the coach switches back to the app, so fresh photos appear without a relaunch.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await loader.refresh(selectedContact: selectedContact, since: dateRange.cutoffDate) }
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
            } else if loader.contacts.isEmpty {
                // DB readable but zero qualifying rows — tell the coach what "qualifying" means
                // instead of showing a silently empty picker.
                Label("no clients with received photos found in whatsapp yet", systemImage: "message.fill")
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
                    appState.whatsAppClientName = contact
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

            // Manual re-query — picks up photos that arrived since the list last loaded.
            Button {
                Task { await loader.refresh(selectedContact: selectedContact, since: dateRange.cutoffDate) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(loader.unavailable || loader.isLoadingContacts)
            .help("Refresh — check WhatsApp for new photos")

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
                .frame(maxWidth: .infinity).frame(height: 132)
        } else if selectedContact == nil {
            Text("Select a client above to see their photos")
                .foregroundColor(.secondary).font(.caption)
                .frame(maxWidth: .infinity).frame(height: 132)
        } else if loader.currentPhotos.isEmpty {
            Text("No photos in this date range")
                .foregroundColor(.secondary).font(.caption)
                .frame(maxWidth: .infinity).frame(height: 132)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(loader.currentPhotos) { item in
                        WAThumbView(item: item, onAssign: onAssign)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .frame(height: 132)
        }
    }
}

// MARK: - Thumbnail

private struct WAThumbView: View {
    let item: WhatsAppMediaItem
    let onAssign: (NSImage, WhatsAppMediaBrowser.AssignSlot) -> Void

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM"; return f
    }()

    // Buttons are ALWAYS visible under each photo — no hover. Hover-reveal on a fast-scrolling
    // horizontal strip was hit-and-miss (the wrong thumb would light up), so the assign buttons
    // now live permanently below the image: reliable, and obvious to a first-time coach.
    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottom) {
                Group {
                    if let t = item.thumb {
                        Image(nsImage: t).resizable().scaledToFill()
                    } else {
                        Color(NSColor.controlColor)
                            .overlay(ProgressView().scaleEffect(0.6))
                    }
                }
                .frame(width: 74, height: 84).clipped()

                Text(Self.dateFmt.string(from: item.date))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(Color.black.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .padding(.bottom, 4)
            }
            .frame(width: 74, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.08), lineWidth: 1))

            VStack(spacing: 3) {
                assignBtn("before", color: .blue,  slot: .lastWeek)
                assignBtn("after",  color: .green, slot: .thisWeek)
            }
            .frame(width: 74)
        }
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
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .background(color.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .buttonStyle(.plain)
    }
}
