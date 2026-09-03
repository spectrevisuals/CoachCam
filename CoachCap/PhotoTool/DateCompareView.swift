import AppKit
import SwiftUI
import SQLite3

// MARK: - Date Group

struct DateGroup: Identifiable {
    let id            = UUID()
    let key:           String   // check-in session range: "startCoreTs|endCoreTs"
    let date:          Date
    let displayString: String   // "3 Jul 2026, 08:15  ·  6 photos"
    let count:         Int
    var showTime:      Bool = false   // true when its day has >1 session
}

// MARK: - Loader

@MainActor
/// True when a text field currently has keyboard focus, so the photo-scrubbing key monitors
/// can let A/D/arrow keystrokes through to the field (e.g. the client search box) instead of
/// moving photos.
func isTextInputFocused() -> Bool {
    guard let responder = NSApp.keyWindow?.firstResponder else { return false }
    return responder is NSText || responder is NSTextView
}

final class DateCompareLoader: ObservableObject {
    @Published var contacts:        [WAContact]           = []
    @Published var selectedContact: String?               = nil
    @Published var dates:           [DateGroup]           = []
    @Published var leftPhotos:      [WhatsAppMediaItem]   = []
    @Published var rightPhotos:     [WhatsAppMediaItem]   = []
    @Published var isLoadingContacts = true
    @Published var isLoadingLeft     = false
    @Published var isLoadingRight    = false

    // Generation guard for the expensive date-refine pass: bumped whenever a new client's dates
    // start loading, so the previous client's refine (which hashes every photo across every date)
    // bails out instead of running to completion and burning CPU after the coach has switched
    // away. Lock-guarded so the detached refine can read it off the main thread.
    private let genLock = NSLock()
    nonisolated(unsafe) private var loadGen = 0
    nonisolated private func bumpGen() -> Int { genLock.lock(); defer { genLock.unlock() }; loadGen += 1; return loadGen }
    nonisolated private func genIsCurrent(_ g: Int) -> Bool { genLock.lock(); defer { genLock.unlock() }; return loadGen == g }

    init() { Task { await loadContacts() } }

    func loadContacts() async {
        let result = await Task.detached { WhatsAppMediaLoader.queryContacts() }.value
        // Keep the existing list on a transient nil (e.g. DB briefly locked during a
        // refresh) rather than blanking the picker.
        if let result { contacts = result }
        isLoadingContacts = false
    }

    /// Tracks the most recent date-load request so a slow refinement for an old contact
    /// can't overwrite the list after the user has switched clients.
    private var latestDatesRequest: String?

    func loadDates(for contact: String) async {
        dates = []; leftPhotos = []; rightPhotos = []
        latestDatesRequest = contact
        let gen = bumpGen()

        // Fast pass: raw per-date counts straight from SQL, so the dropdown appears at once.
        let raw = await Task.detached { DateCompareLoader.queryDates(for: contact) }.value
        guard latestDatesRequest == contact else { return }
        dates = raw

        // Refine pass: recompute each count with HD/standard duplicates collapsed, so the
        // dropdown matches what's shown when a date is opened. Hashes are cached, so opening
        // a date afterwards is instant. Bails early if a newer client load has started, so we
        // don't hash a whole client's photo history after the coach has switched away.
        let refined: [DateGroup]? = await Task.detached(priority: .utility) { [weak self] in
            var out: [DateGroup] = []
            out.reserveCapacity(raw.count)
            for group in raw {
                guard self?.genIsCurrent(gen) ?? false else { return nil }
                let rows  = DateCompareLoader.queryPhotosOnDate(contact: contact, dateKey: group.key)
                let count = WhatsAppMediaLoader.dedupHDDuplicates(rows).count
                out.append(DateGroup(key: group.key, date: group.date,
                                     displayString: DateCompareLoader.dateDisplay(group.date, count: count, withTime: group.showTime),
                                     count: count, showTime: group.showTime))
            }
            return out
        }.value
        guard let refined, latestDatesRequest == contact else { return }
        dates = refined
    }

    func loadSide(_ side: Side, contact: String, dateKey: String) async {
        if side == .left { isLoadingLeft = true } else { isLoadingRight = true }
        let items = await Task.detached(priority: .userInitiated) {
            // WhatsApp delivers HD photos as a second, higher-res copy of the standard
            // one, so an 8-photo check-in lands as 16 rows. Collapse the duplicate pairs
            // (keeping the HD copy) before building thumbnails.
            let rows = DateCompareLoader.queryPhotosOnDate(contact: contact, dateKey: dateKey)
            return WhatsAppMediaLoader.dedupHDDuplicates(rows)
                .map { item -> WhatsAppMediaItem in
                    var copy = item
                    copy.thumb = WhatsAppMediaLoader.makeThumbnail(item.url, maxPx: 1600)
                    return copy
                }
        }.value
        if side == .left { leftPhotos = items; isLoadingLeft = false }
        else             { rightPhotos = items; isLoadingRight = false }
    }

    enum Side { case left, right }

    // MARK: SQLite

    /// Photos sent more than this far apart start a new "check-in session". Lets clients who
    /// check in several times a day (e.g. show prep) be picked by time, not just by date.
    private static let sessionGapSeconds: Double = 2 * 3600

    /// Groups a contact's incoming photos into check-in sessions, splitting a day wherever
    /// there's a >2h gap. Each session's `key` encodes its Core Data time range
    /// ("start|end") so `queryPhotosOnDate` can fetch exactly that session — the pickers and
    /// loaders don't need to change. Days with a single session read as before; days with more
    /// than one also show the time.
    nonisolated static func queryDates(for contact: String) -> [DateGroup] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(WhatsAppMediaLoader.dbPath, &db,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT m.ZMESSAGEDATE
            FROM ZWAMESSAGE m
            JOIN ZWAMEDIAITEM mi ON mi.ZMESSAGE = m.Z_PK
            JOIN ZWACHATSESSION cs ON cs.Z_PK = m.ZCHATSESSION
            WHERE cs.ZPARTNERNAME = ?
              AND m.ZISFROMME = 0
              AND (mi.ZMEDIALOCALPATH LIKE '%.jpg'  OR mi.ZMEDIALOCALPATH LIKE '%.jpeg'
                OR mi.ZMEDIALOCALPATH LIKE '%.png'  OR mi.ZMEDIALOCALPATH LIKE '%.heic')
            ORDER BY m.ZMESSAGEDATE ASC
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        let TR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, contact, -1, TR)

        // Cluster the (ascending) timestamps into sessions by the gap threshold. Timestamps are
        // Core Data epoch (seconds since 2001); +978307200 converts to unix.
        struct Sess { var start: Double; var end: Double; var count: Int }
        var sessions: [Sess] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let t = sqlite3_column_double(stmt, 0)
            if var last = sessions.last, t - last.end <= sessionGapSeconds {
                last.end = t; last.count += 1; sessions[sessions.count - 1] = last
            } else {
                sessions.append(Sess(start: t, end: t, count: 1))
            }
        }
        guard !sessions.isEmpty else { return [] }

        // A day with more than one session shows the time on each entry.
        let cal = Calendar.current
        func day(_ coreTs: Double) -> Date { cal.startOfDay(for: Date(timeIntervalSince1970: coreTs + 978307200)) }
        var sessionsPerDay: [Date: Int] = [:]
        for s in sessions { sessionsPerDay[day(s.start), default: 0] += 1 }

        // Most-recent first.
        return sessions.reversed().map { s in
            let date = Date(timeIntervalSince1970: s.start + 978307200)
            let showTime = (sessionsPerDay[day(s.start)] ?? 1) > 1
            return DateGroup(key: "\(s.start)|\(s.end)", date: date,
                             displayString: dateDisplay(date, count: s.count, withTime: showTime),
                             count: s.count, showTime: showTime)
        }
    }

    private static let dateDisplayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM yyyy"; return f
    }()
    private static let timeDisplayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    nonisolated static func dateDisplay(_ date: Date, count: Int, withTime: Bool = false) -> String {
        let stamp = withTime
            ? "\(dateDisplayFmt.string(from: date)), \(timeDisplayFmt.string(from: date))"
            : dateDisplayFmt.string(from: date)
        return "\(stamp)  ·  \(count) photo\(count == 1 ? "" : "s")"
    }

    nonisolated static func queryPhotosOnDate(contact: String, dateKey: String) -> [WhatsAppMediaItem] {
        // dateKey is a session range "startCoreTs|endCoreTs" produced by queryDates.
        let parts = dateKey.split(separator: "|")
        guard parts.count == 2, let startTs = Double(parts[0]), let endTs = Double(parts[1]) else { return [] }

        var db: OpaquePointer?
        guard sqlite3_open_v2(WhatsAppMediaLoader.dbPath, &db,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT mi.ZMEDIALOCALPATH, m.ZMESSAGEDATE+978307200, mi.ZFILESIZE
            FROM ZWAMESSAGE m
            JOIN ZWAMEDIAITEM mi ON mi.ZMESSAGE = m.Z_PK
            JOIN ZWACHATSESSION cs ON cs.Z_PK = m.ZCHATSESSION
            WHERE cs.ZPARTNERNAME = ?
              AND m.ZISFROMME = 0
              AND m.ZMESSAGEDATE >= ? AND m.ZMESSAGEDATE <= ?
              AND (mi.ZMEDIALOCALPATH LIKE '%.jpg'  OR mi.ZMEDIALOCALPATH LIKE '%.jpeg'
                OR mi.ZMEDIALOCALPATH LIKE '%.png'  OR mi.ZMEDIALOCALPATH LIKE '%.heic')
            ORDER BY m.ZMESSAGEDATE ASC
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        let TR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, contact, -1, TR)
        sqlite3_bind_double(stmt, 2, startTs)
        sqlite3_bind_double(stmt, 3, endTs)

        var out: [WhatsAppMediaItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let c = sqlite3_column_text(stmt, 0) else { continue }
            let rel  = String(cString: c)
            let ts   = sqlite3_column_double(stmt, 1)
            let size = Int(sqlite3_column_int64(stmt, 2))
            let full = (WhatsAppMediaLoader.mediaBase as NSString).appendingPathComponent(rel)
            guard FileManager.default.fileExists(atPath: full) else { continue }
            out.append(WhatsAppMediaItem(url: URL(fileURLWithPath: full),
                                         date: Date(timeIntervalSince1970: ts),
                                         fileSize: size))
        }
        return out
    }
}

// MARK: - Browse View (shared client, two independent date panels)

struct BrowseView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var contactLoader = DateCompareLoader()
    @State private var selectedContact: String? = nil
    @State private var leftIndex    = 0
    @State private var rightIndex   = 0
    @State private var leftDateKey:  String? = nil
    @State private var rightDateKey: String? = nil
    @State private var leftCount    = 0
    @State private var rightCount   = 0
    @State private var keyMonitor:  Any? = nil
    @State private var leftPhotos:  [WhatsAppMediaItem] = []
    @State private var rightPhotos: [WhatsAppMediaItem] = []
    @State private var aiMatches:   [PoseMatch] = []
    @State private var aiMatchIdx   = 0
    // Indices of AI matches the coach has re-paired by hand (for the ✎ "edited" badge).
    @State private var aiEdited:    Set<Int> = []
    // Explicit "fix this pairing" mode. While editing, ← / → (and the on-screen arrows) scrub
    // the AFTER photo instead of stepping between poses — so you can line the match up without
    // jumping away — then "save match" locks it and hands the arrows back to pose-stepping.
    @State private var editingMatch = false
    @State private var editBackup:  PoseMatch? = nil   // for "cancel" — restore the pre-edit pairing
    // Free-scrub mode: keyboard drives the two panels independently (letters = before/left,
    // arrows = after/right), ignoring AI stepping — the old "just flick through by hand" feel.
    @State private var manualScroll = false
    // "sort before / after" — hand-tagged photo sets that override the date pickers, for a
    // client who sent before + after in one mixed batch. nil = normal date-browsing.
    @State private var showSortSheet  = false
    @State private var leftOverride:  [WhatsAppMediaItem]? = nil
    @State private var rightOverride: [WhatsAppMediaItem]? = nil
    @State private var aiLoading    = false
    @State private var aiError:     String? = nil
    // Bumped to tell the two panels to re-query WhatsApp for newly-arrived photos.
    @State private var refreshToken = 0
    // Free-text filter for the client picker (the list is long; recency order alone isn't
    // enough to find an older client quickly).
    @State private var contactSearch = ""
    // Debounced copy of `contactSearch` that actually drives the filtered list. Each keystroke
    // re-evaluates this whole view (which includes the photo panels), so filtering off the raw
    // field made every character re-render the grids on the main thread — the source of the
    // progressive beachball while searching. Debouncing coalesces a burst of typing into one
    // update ~220ms after the coach stops, keeping the field itself responsive.
    @State private var contactQuery = ""
    @State private var searchDebounce: Task<Void, Never>?
    // Tracks search-field focus so we can hand keyboard control BACK to photo scrubbing
    // (A/D + arrows) the moment the coach is done searching — otherwise the field keeps
    // swallowing those keys.
    @FocusState private var searchFocused: Bool

    private var filteredContacts: [WAContact] {
        let q = contactQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return contactLoader.contacts }
        return contactLoader.contacts.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "person.fill").foregroundColor(.secondary).font(.caption)
                if contactLoader.isLoadingContacts {
                    ProgressView().scaleEffect(0.6)
                } else {
                    // Type-to-search filter for the client list.
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                        TextField("Search clients", text: $contactSearch)
                            .textFieldStyle(.plain)
                            .frame(width: 120)
                            .focused($searchFocused)
                            // Debounce filtering so a burst of typing doesn't re-render the photo
                            // panels on every keystroke. Empty resets instantly (clearing feels snappy).
                            .onChange(of: contactSearch) { _, v in
                                searchDebounce?.cancel()
                                if v.isEmpty { contactQuery = ""; return }
                                searchDebounce = Task {
                                    try? await Task.sleep(nanoseconds: 220_000_000)
                                    if !Task.isCancelled { contactQuery = v }
                                }
                            }
                            // Return/Esc hand control back to photo scrubbing.
                            .onSubmit { dropSearchFocus() }
                            .onExitCommand { contactSearch = ""; dropSearchFocus() }
                        if !contactSearch.isEmpty {
                            Button { contactSearch = ""; dropSearchFocus() } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                            }
                            .buttonStyle(.plain).foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Brand.control))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Brand.controlBorder, lineWidth: 1))

                    Picker("Client", selection: $selectedContact) {
                        Text("Select client…").tag(String?.none)
                        ForEach(filteredContacts) { c in
                            Text("\(c.name)  (\(c.photoCount))").tag(Optional(c.name))
                        }
                    }
                    .labelsHidden().frame(width: 240)
                    .onChange(of: selectedContact) { _, c in
                        appState.whatsAppClientName = c
                        // Picked a client — clear the box and hand keyboard control back to
                        // photo scrubbing so A/D + arrows work immediately.
                        contactSearch = ""
                        dropSearchFocus()
                    }
                }

                // Re-query WhatsApp for photos that arrived since this screen loaded, so the
                // coach doesn't have to quit and relaunch when a new check-in comes through.
                Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .disabled(contactLoader.isLoadingContacts)
                    .help("Refresh — check WhatsApp for new photos")

                Divider().frame(height: 20)

                // Manual scroll — flick through each side by hand with the keyboard.
                Button {
                    manualScroll.toggle()
                    if manualScroll { editingMatch = false }   // the two modes are mutually exclusive
                } label: {
                    Label("manual scroll", systemImage: "arrow.left.and.right")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .tint(manualScroll ? Brand.accent : .secondary)
                .help("Scroll each side by hand: W A S D move the before photo, ← / → move the after")

                // Sort before / after — client sent before + after (+ other shots) in one batch.
                Button { showSortSheet = true } label: {
                    Label("sort before / after", systemImage: "square.grid.2x2")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                .disabled(selectedContact == nil)
                .help("Client sent before + after in one batch (missed a week)? Tag which photos are before and which are after, and leave the rest out of the comparison.")

                // Showing a hand-sorted set — offer a way back to the date pickers.
                if leftOverride != nil || rightOverride != nil {
                    Button { clearSorted() } label: {
                        Label("sorted batch", systemImage: "xmark.circle.fill")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.borderedProminent).tint(Brand.accent)
                    .help("Back to browsing by date")
                }

                Divider().frame(height: 20)

                // AI match
                if !aiMatches.isEmpty {
                    if editingMatch {
                        // Fixing the current pair: scrub the AFTER photo, then lock it in.
                        HStack(spacing: 8) {
                            Text("fixing \(aiMatches[aiMatchIdx].pose.lowercased())")
                                .font(.caption.bold()).foregroundColor(Brand.accent)
                            Button { nudgeRight(-1) } label: { Image(systemName: "chevron.left") }
                                .buttonStyle(.plain).disabled(rightIndex == 0)
                            Text("after photo \(rightIndex + 1)/\(max(rightCount, 1))")
                                .font(.caption).foregroundColor(.secondary)
                            Button { nudgeRight(1) } label: { Image(systemName: "chevron.right") }
                                .buttonStyle(.plain).disabled(rightIndex >= rightCount - 1)
                            Button("save match") { saveMatch() }
                                .buttonStyle(.borderedProminent).font(.caption)
                            Button("cancel") { cancelEdit() }
                                .buttonStyle(.link).font(.caption)
                        }
                    } else {
                        HStack(spacing: 8) {
                            Button { stepAIMatch(-1) } label: { Image(systemName: "chevron.left") }
                                .buttonStyle(.plain).disabled(aiMatchIdx == 0)
                            Text("AI: \(aiMatches[aiMatchIdx].pose.capitalized)  \(aiMatchIdx+1)/\(aiMatches.count)\(aiEdited.contains(aiMatchIdx) ? "  ✎" : "")")
                                .font(.caption.bold()).foregroundColor(.blue)
                                .help(aiEdited.contains(aiMatchIdx) ? "You corrected this pairing by hand" : "")
                            Button { stepAIMatch(1) } label: { Image(systemName: "chevron.right") }
                                .buttonStyle(.plain).disabled(aiMatchIdx == aiMatches.count - 1)
                            Button("ai match wrong?") { beginEdit() }
                                .buttonStyle(.bordered).font(.caption)
                                .help("Line up the correct after photo for this pose, then save it")
                            Button("Clear") { aiMatches = []; aiMatchIdx = 0; aiEdited = []; editingMatch = false }
                                .buttonStyle(.link).font(.caption)
                        }
                    }
                } else if aiLoading {
                    ProgressView().scaleEffect(0.7)
                    Text("Matching poses…").font(.caption).foregroundColor(.secondary)
                } else {
                    Button {
                        runAIMatch(leftURLs: leftPhotos.map(\.url), rightURLs: rightPhotos.map(\.url))
                    } label: {
                        Label("AI Match", systemImage: "sparkles")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .disabled(leftPhotos.isEmpty || rightPhotos.isEmpty)
                    .help("Automatically pair matching poses using AI")
                }

                if let err = aiError {
                    Text(err).font(.caption).foregroundColor(.red).lineLimit(1)
                }

                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Brand.bgElev)

            // Prominent, always-visible fallback: AI match isn't perfect, so make manual
            // scrubbing unmistakable. Full-width accent strip under the toolbar.
            HStack(spacing: 8) {
                Image(systemName: "keyboard").foregroundColor(Brand.accent)
                Text(.init(hintText))
                    .font(Brand.font(12))
                    .foregroundColor(Brand.text.opacity(0.9))
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((editingMatch || manualScroll) ? Brand.accent.opacity(0.22) : Brand.accentSoft)

            Divider()

            HStack(spacing: 0) {
                BrowsePanelView(contact: selectedContact,
                                refreshToken: refreshToken,
                                index: $leftIndex,
                                photoCount: $leftCount,
                                photos: $leftPhotos,
                                dateKey: $leftDateKey,
                                sideLabel: "before",
                                override: leftOverride)
                Rectangle().fill(Color.white.opacity(0.2)).frame(width: 2)
                BrowsePanelView(contact: selectedContact,
                                refreshToken: refreshToken,
                                index: $rightIndex,
                                photoCount: $rightCount,
                                photos: $rightPhotos,
                                dateKey: $rightDateKey,
                                sideLabel: "after",
                                override: rightOverride)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
        }
        .onAppear  { startKeyMonitor() }
        .onDisappear { stopKeyMonitor() }
        .sheet(isPresented: $showSortSheet) {
            SortBatchSheet(contact: selectedContact,
                           initialDateKey: leftDateKey,
                           onCompare: { before, after in applySorted(before: before, after: after) },
                           onCancel: { showSortSheet = false })
        }
        // New check-in photos land in WhatsApp while CoachCam stays open. On returning to the
        // app, refresh ONLY the contact list (counts) — NOT the photo panels. The coach tabs
        // to WhatsApp and back constantly; reloading the panels here would wipe an in-progress
        // AI match and flash the photos. New photos for the open client are pulled with the
        // explicit refresh button.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await contactLoader.loadContacts() }
        }
    }

    /// Reliably hand keyboard focus back to photo scrubbing. `@FocusState = false` alone is
    /// flaky on macOS (works on some machines, not others — which is why A/D scrubbing broke
    /// for the client but not locally), so we also resign the window's first responder at the
    /// AppKit level, which actually releases the search field's editor.
    private func dropSearchFocus() {
        searchFocused = false
        DispatchQueue.main.async {
            if let win = NSApp.keyWindow, win.firstResponder is NSText || win.firstResponder is NSTextView {
                win.makeFirstResponder(nil)
            }
        }
    }

    /// Manual refresh: reloads the contact list and signals both photo panels to re-query.
    /// This DOES reset an in-progress AI match — it's only triggered by the explicit button.
    private func refresh() {
        Task { await contactLoader.loadContacts() }
        refreshToken &+= 1
    }

    private func runAIMatch(leftURLs: [URL], rightURLs: [URL]) {
        guard !leftURLs.isEmpty, !rightURLs.isEmpty else { return }
        aiLoading = true; aiError = nil; aiMatches = []
        Task {
            do {
                let matches = try await AIMatchEngine.shared.matchPoses(leftURLs: leftURLs,
                                                                         rightURLs: rightURLs)
                aiMatches  = matches
                aiMatchIdx = 0
                aiEdited   = []   // fresh AI run — clear any prior hand corrections
                if let first = matches.first {
                    leftIndex  = first.leftIndex
                    rightIndex = first.rightIndex
                }
            } catch {
                aiError = error.localizedDescription
            }
            aiLoading = false
        }
    }

    /// The accent strip under the toolbar — reflects the current keyboard mode.
    private var hintText: String {
        if manualScroll {
            return "Manual scroll: **W A S D** flick the before photo, **← / →** flick the after. Turn off *manual scroll* to go back to AI poses."
        }
        if editingMatch {
            return "Lining up the **after** photo — use **← / →** (or the arrows above). Hit **save match** when it's right, or **cancel**."
        }
        return "Step through poses with **← / →**. AI got a pairing wrong? Hit **ai match wrong?** to line up the correct after photo, then lock it in."
    }

    private func stepAIMatch(_ delta: Int) {
        // Never jump poses mid-edit — you must save or cancel first (that's the "lock").
        guard !editingMatch else { return }
        let next = aiMatchIdx + delta
        guard aiMatches.indices.contains(next) else { return }
        aiMatchIdx = next
        leftIndex  = aiMatches[next].leftIndex
        rightIndex = aiMatches[next].rightIndex
    }

    private func nudgeLeft(_ delta: Int)  { leftIndex  = max(0, min(leftCount  - 1, leftIndex  + delta)) }
    private func nudgeRight(_ delta: Int) { rightIndex = max(0, min(rightCount - 1, rightIndex + delta)) }

    /// Apply a hand-sorted batch: the before-tagged photos become the left (before) sequence,
    /// the after-tagged become the right. Clears any AI match; leaves the keyboard mode alone
    /// (the coach can still click each panel's arrows, or turn on manual scroll themselves).
    private func applySorted(before: [WhatsAppMediaItem], after: [WhatsAppMediaItem]) {
        leftOverride = before; rightOverride = after
        leftPhotos = before;   rightPhotos = after
        leftCount = before.count; rightCount = after.count
        leftIndex = 0; rightIndex = 0
        aiMatches = []; aiMatchIdx = 0; aiEdited = []; editingMatch = false
        showSortSheet = false
    }

    /// Drop the hand-sorted set and go back to browsing by date.
    private func clearSorted() {
        leftOverride = nil; rightOverride = nil
        leftIndex = 0; rightIndex = 0
    }

    /// Enter "fix this pairing" mode for the current AI pose. Stashes the current pairing so
    /// "cancel" can put it back untouched.
    private func beginEdit() {
        guard aiMatches.indices.contains(aiMatchIdx) else { return }
        editBackup = aiMatches[aiMatchIdx]
        editingMatch = true
    }

    /// Lock the coach's pairing into the AI sequence and hand the arrows back to pose-stepping.
    private func saveMatch() {
        if aiMatches.indices.contains(aiMatchIdx) {
            let pose = aiMatches[aiMatchIdx].pose
            aiMatches[aiMatchIdx] = PoseMatch(leftIndex: leftIndex, rightIndex: rightIndex, pose: pose)
            aiEdited.insert(aiMatchIdx)
        }
        editingMatch = false
        editBackup = nil
    }

    /// Bail out without changing the pairing — restore what it was before editing.
    private func cancelEdit() {
        if let b = editBackup {
            leftIndex  = b.leftIndex
            rightIndex = b.rightIndex
        }
        editingMatch = false
        editBackup = nil
    }

    private func startKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Don't hijack keys while the coach is typing (e.g. the client search box).
            if isTextInputFocused() { return event }
            let left   = event.keyCode == 123
            let right  = event.keyCode == 124
            let a      = event.keyCode == 0    // A
            let d      = event.keyCode == 2    // D
            let w      = event.keyCode == 13   // W
            let s      = event.keyCode == 1    // S
            let enter  = event.keyCode == 36 || event.keyCode == 76   // Return / numpad Enter
            let escape = event.keyCode == 53
            guard left || right || a || d || w || s || enter || escape else { return event }

            // ── Manual scroll: the whole WASD cluster flicks the BEFORE (left) photo, the arrows
            //    flick the AFTER (right) photo — two independent scrubbers, no AI stepping.
            if self.manualScroll {
                if d || w { self.nudgeLeft(1) }    // forward on the before photo
                if a || s { self.nudgeLeft(-1) }   // back
                if right  { self.nudgeRight(1) }
                if left   { self.nudgeRight(-1) }
                return nil
            }

            // ── Editing a pairing: arrows (and W/S) scrub the AFTER photo; A/D nudge the before;
            //    Enter locks it, Esc bails. Stepping between poses is disabled until you commit.
            if self.editingMatch {
                if enter  { self.saveMatch();  return nil }
                if escape { self.cancelEdit(); return nil }
                if a { self.nudgeLeft(-1) }
                if d { self.nudgeLeft(1) }
                if left  || s { self.nudgeRight(-1) }
                if right || w { self.nudgeRight(1) }
                return nil
            }

            // ── Not editing: ← / → step between the AI-matched poses (same as the ‹ › buttons).
            if left || right {
                if !self.aiMatches.isEmpty {
                    if left  { self.stepAIMatch(-1) }
                    if right { self.stepAIMatch(1) }
                }
                return nil
            }
            // A/D/W/S drop straight into edit mode for this pose and apply the first nudge, so
            // keyboard-first coaches don't have to reach for the button.
            if a || d || w || s, !self.aiMatches.isEmpty {
                self.beginEdit()
                if a { self.nudgeLeft(-1) }
                if d { self.nudgeLeft(1) }
                if s { self.nudgeRight(-1) }
                if w { self.nudgeRight(1) }
                return nil
            }
            return nil
        }
    }

    private func stopKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }
}

// MARK: Single browse panel (date + arrows only)

private struct BrowsePanelView: View {
    let contact: String?
    var refreshToken: Int = 0
    @Binding var index: Int
    @Binding var photoCount: Int
    @Binding var photos: [WhatsAppMediaItem]
    // Hoisted to the parent so a shared date can be pushed onto both sides.
    @Binding var dateKey: String?
    // "before" / "after" — shown when displaying a hand-sorted set.
    var sideLabel: String = ""
    // When set (from "sort before / after"), the panel shows this exact list instead of a date.
    var override: [WhatsAppMediaItem]? = nil

    @StateObject private var loader = DateCompareLoader()

    private var currentPhotos: [WhatsAppMediaItem] { override ?? loader.leftPhotos }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.white.opacity(0.15))
            photoArea
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: contact) { _, newContact in
            dateKey = nil; index = 0
            loader.leftPhotos = []
            if let c = newContact { Task { await loader.loadDates(for: c) } }
            else { loader.dates = [] }
        }
        .onChange(of: dateKey) { _, key in
            index = 0
            if let key, let c = contact {
                Task { await loader.loadSide(.left, contact: c, dateKey: key) }
            }
        }
        .onChange(of: currentPhotos.count) { _, count in
            photoCount = count
            photos     = currentPhotos
            if index >= count { index = max(0, count - 1) }
        }
        .onChange(of: refreshToken) { _, _ in
            guard let c = contact else { return }
            // Re-query: refresh the date list (new check-ins appear as new dates) and reload
            // the currently-open date so extra photos on it show up. Keep the open date if it
            // still exists.
            let keepDate = dateKey
            Task {
                await loader.loadDates(for: c)
                if let keepDate, loader.dates.contains(where: { $0.key == keepDate }) {
                    await loader.loadSide(.left, contact: c, dateKey: keepDate)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            // Date picker (or a "sorted" label when showing a hand-tagged set)
            if override != nil {
                Label("sorted • \(sideLabel)", systemImage: "square.grid.2x2")
                    .font(.caption.bold()).foregroundColor(Brand.accent)
            } else if contact == nil {
                Text("← Select a client first")
                    .foregroundColor(.secondary).font(.caption)
            } else if loader.dates.isEmpty && !loader.isLoadingLeft {
                Text("No photos found")
                    .foregroundColor(.secondary).font(.caption)
            } else {
                Picker("Date", selection: $dateKey) {
                    Text("Pick a date…").tag(String?.none)
                    ForEach(loader.dates) { d in
                        Text(d.displayString).tag(Optional(d.key))
                    }
                }
                .labelsHidden()
                .frame(width: 260)
                .colorScheme(.dark)
            }

            Spacer()

            // Arrows + counter
            if !currentPhotos.isEmpty {
                HStack(spacing: 12) {
                    Button { index = max(0, index - 1) } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(index == 0 ? .white.opacity(0.25) : .white)
                    .disabled(index == 0)

                    Text("\(index + 1) / \(currentPhotos.count)")
                        .font(.system(.caption, design: .monospaced).bold())
                        .foregroundColor(.white)
                        .frame(minWidth: 50)

                    Button { index = min(currentPhotos.count - 1, index + 1) } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(index == currentPhotos.count - 1 ? .white.opacity(0.25) : .white)
                    .disabled(index == currentPhotos.count - 1)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.black.opacity(0.5))
    }

    @ViewBuilder
    private var photoArea: some View {
        if loader.isLoadingLeft {
            ProgressView("Loading…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
        } else if currentPhotos.isEmpty {
            Brand.bg.overlay(
                BrandEmptyState(icon: dateKey == nil ? "calendar" : "photo.on.rectangle",
                                title: dateKey == nil ? "pick a date" : "no photos",
                                subtitle: dateKey == nil ? "choose a check-in date above" : "no photos on this date",
                                iconSize: 20, boxSize: 48)
            )
        } else if currentPhotos.indices.contains(index) {
            ZStack {
                Color.black
                if let t = currentPhotos[index].thumb {
                    ZoomablePhoto { WatermarkedImage(image: t) }
                        .id(currentPhotos[index].id)   // reset zoom when the photo changes
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color.black.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
