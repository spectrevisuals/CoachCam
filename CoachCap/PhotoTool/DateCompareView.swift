import AppKit
import SwiftUI
import SQLite3

// MARK: - Date Group

struct DateGroup: Identifiable {
    let id            = UUID()
    let key:           String   // "yyyy-MM-dd"
    let date:          Date
    let displayString: String   // "3 Jun 2026  (6 photos)"
    let count:         Int
}

// MARK: - Loader

@MainActor
final class DateCompareLoader: ObservableObject {
    @Published var contacts:        [WAContact]           = []
    @Published var selectedContact: String?               = nil
    @Published var dates:           [DateGroup]           = []
    @Published var leftPhotos:      [WhatsAppMediaItem]   = []
    @Published var rightPhotos:     [WhatsAppMediaItem]   = []
    @Published var isLoadingContacts = true
    @Published var isLoadingLeft     = false
    @Published var isLoadingRight    = false

    init() { Task { await loadContacts() } }

    func loadContacts() async {
        let result = await Task.detached { WhatsAppMediaLoader.queryContacts() }.value
        contacts = result ?? []
        isLoadingContacts = false
    }

    /// Tracks the most recent date-load request so a slow refinement for an old contact
    /// can't overwrite the list after the user has switched clients.
    private var latestDatesRequest: String?

    func loadDates(for contact: String) async {
        dates = []; leftPhotos = []; rightPhotos = []
        latestDatesRequest = contact

        // Fast pass: raw per-date counts straight from SQL, so the dropdown appears at once.
        let raw = await Task.detached { DateCompareLoader.queryDates(for: contact) }.value
        guard latestDatesRequest == contact else { return }
        dates = raw

        // Refine pass: recompute each count with HD/standard duplicates collapsed, so the
        // dropdown matches what's shown when a date is opened. Hashes are cached, so opening
        // a date afterwards is instant.
        let refined = await Task.detached(priority: .utility) {
            raw.map { group -> DateGroup in
                let rows  = DateCompareLoader.queryPhotosOnDate(contact: contact, dateKey: group.key)
                let count = WhatsAppMediaLoader.dedupHDDuplicates(rows).count
                return DateGroup(key: group.key, date: group.date,
                                 displayString: DateCompareLoader.dateDisplay(group.date, count: count),
                                 count: count)
            }
        }.value
        guard latestDatesRequest == contact else { return }
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

    nonisolated static func queryDates(for contact: String) -> [DateGroup] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(WhatsAppMediaLoader.dbPath, &db,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT strftime('%Y-%m-%d', (m.ZMESSAGEDATE+978307200), 'unixepoch','localtime') AS d,
                   COUNT(*) AS cnt,
                   MIN(m.ZMESSAGEDATE+978307200) AS minTs
            FROM ZWAMESSAGE m
            JOIN ZWAMEDIAITEM mi ON mi.ZMESSAGE = m.Z_PK
            JOIN ZWACHATSESSION cs ON cs.Z_PK = m.ZCHATSESSION
            WHERE cs.ZPARTNERNAME = ?
              AND m.ZISFROMME = 0
              AND (mi.ZMEDIALOCALPATH LIKE '%.jpg'  OR mi.ZMEDIALOCALPATH LIKE '%.jpeg'
                OR mi.ZMEDIALOCALPATH LIKE '%.png'  OR mi.ZMEDIALOCALPATH LIKE '%.heic')
            GROUP BY d ORDER BY d DESC
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        let TR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, contact, -1, TR)

        var out: [DateGroup] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let k = sqlite3_column_text(stmt, 0) else { continue }
            let key   = String(cString: k)
            let count = Int(sqlite3_column_int(stmt, 1))
            let date  = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
            out.append(DateGroup(key: key, date: date,
                                 displayString: dateDisplay(date, count: count), count: count))
        }
        return out
    }

    private static let dateDisplayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM yyyy"; return f
    }()

    nonisolated static func dateDisplay(_ date: Date, count: Int) -> String {
        "\(dateDisplayFmt.string(from: date))  ·  \(count) photo\(count == 1 ? "" : "s")"
    }

    nonisolated static func queryPhotosOnDate(contact: String, dateKey: String) -> [WhatsAppMediaItem] {
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
              AND strftime('%Y-%m-%d',(m.ZMESSAGEDATE+978307200),'unixepoch','localtime') = ?
              AND (mi.ZMEDIALOCALPATH LIKE '%.jpg'  OR mi.ZMEDIALOCALPATH LIKE '%.jpeg'
                OR mi.ZMEDIALOCALPATH LIKE '%.png'  OR mi.ZMEDIALOCALPATH LIKE '%.heic')
            ORDER BY m.ZMESSAGEDATE ASC
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        let TR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, contact, -1, TR)
        sqlite3_bind_text(stmt, 2, dateKey, -1, TR)

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
    @StateObject private var contactLoader = DateCompareLoader()
    @State private var selectedContact: String? = nil
    @State private var linked       = false
    @State private var reverseControls = false
    @State private var leftIndex    = 0
    @State private var rightIndex   = 0
    @State private var linkedIndex  = 0
    @State private var leftCount    = 0
    @State private var rightCount   = 0
    @State private var keyMonitor:  Any? = nil
    @State private var leftPhotos:  [WhatsAppMediaItem] = []
    @State private var rightPhotos: [WhatsAppMediaItem] = []
    @State private var aiMatches:   [PoseMatch] = []
    @State private var aiMatchIdx   = 0
    @State private var aiLoading    = false
    @State private var aiError:     String? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "person.fill").foregroundColor(.secondary).font(.caption)
                if contactLoader.isLoadingContacts {
                    ProgressView().scaleEffect(0.6)
                } else {
                    Picker("Client", selection: $selectedContact) {
                        Text("Select client…").tag(String?.none)
                        ForEach(contactLoader.contacts) { c in
                            Text("\(c.name)  (\(c.photoCount))").tag(Optional(c.name))
                        }
                    }
                    .labelsHidden().frame(width: 240)
                }

                Divider().frame(height: 20)

                Toggle(isOn: $linked) {
                    Label("Sync arrows", systemImage: linked ? "link" : "link.badge.plus")
                        .font(.caption)
                }
                .toggleStyle(.checkbox)
                .onChange(of: linked) { _, on in if on { linkedIndex = leftIndex } }

                Divider().frame(height: 20)

                Toggle(isOn: $reverseControls) {
                    Label("Reverse WASD", systemImage: reverseControls ? "arrow.2.squarepath" : "keyboard")
                        .font(.caption)
                }
                .toggleStyle(.checkbox)

                Divider().frame(height: 20)

                // AI match
                if !aiMatches.isEmpty {
                    HStack(spacing: 8) {
                        Button { stepAIMatch(-1) } label: { Image(systemName: "chevron.left") }
                            .buttonStyle(.plain).disabled(aiMatchIdx == 0)
                        Text("AI: \(aiMatches[aiMatchIdx].pose.capitalized)  \(aiMatchIdx+1)/\(aiMatches.count)")
                            .font(.caption.bold()).foregroundColor(.blue)
                        Button { stepAIMatch(1) } label: { Image(systemName: "chevron.right") }
                            .buttonStyle(.plain).disabled(aiMatchIdx == aiMatches.count - 1)
                        Button("Clear") { aiMatches = []; aiMatchIdx = 0 }
                            .buttonStyle(.link).font(.caption)
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
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            HStack(spacing: 0) {
                BrowsePanelView(contact: selectedContact,
                                index: linked ? $linkedIndex : $leftIndex,
                                photoCount: $leftCount,
                                photos: $leftPhotos)
                Rectangle().fill(Color.white.opacity(0.2)).frame(width: 2)
                BrowsePanelView(contact: selectedContact,
                                index: linked ? $linkedIndex : $rightIndex,
                                photoCount: $rightCount,
                                photos: $rightPhotos)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
        }
        .onAppear  { startKeyMonitor() }
        .onDisappear { stopKeyMonitor() }
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

    private func stepAIMatch(_ delta: Int) {
        let next = aiMatchIdx + delta
        guard aiMatches.indices.contains(next) else { return }
        aiMatchIdx = next
        leftIndex  = aiMatches[next].leftIndex
        rightIndex = aiMatches[next].rightIndex
    }

    private func startKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let isArrowLeft  = event.keyCode == 123
            let isArrowRight = event.keyCode == 124
            let isWASDLeft   = event.keyCode == 0  // A
            let isWASDRight  = event.keyCode == 2  // D

            guard isArrowLeft || isArrowRight || isWASDLeft || isWASDRight else { return event }

            // When AI matches are active, arrows step through pairs
            if !self.aiMatches.isEmpty && (isArrowLeft || isArrowRight) {
                if isArrowLeft  { self.stepAIMatch(-1) }
                if isArrowRight { self.stepAIMatch(1) }
                return nil
            }

            // Determine which side gets arrows vs WASD
            let arrowControlsLeft = !self.reverseControls

            if self.linked {
                let cap = max(self.leftCount, self.rightCount)
                if isArrowLeft  || isWASDLeft  { self.linkedIndex = max(0, self.linkedIndex - 1) }
                if isArrowRight || isWASDRight { self.linkedIndex = min(cap - 1, self.linkedIndex + 1) }
            } else {
                // Arrows control one side, WASD controls the other
                if arrowControlsLeft {
                    if isArrowLeft  { self.leftIndex = max(0, self.leftIndex - 1) }
                    if isArrowRight { self.leftIndex = min(self.leftCount - 1, self.leftIndex + 1) }
                    if isWASDLeft   { self.rightIndex = max(0, self.rightIndex - 1) }
                    if isWASDRight  { self.rightIndex = min(self.rightCount - 1, self.rightIndex + 1) }
                } else {
                    if isArrowLeft  { self.rightIndex = max(0, self.rightIndex - 1) }
                    if isArrowRight { self.rightIndex = min(self.rightCount - 1, self.rightIndex + 1) }
                    if isWASDLeft   { self.leftIndex = max(0, self.leftIndex - 1) }
                    if isWASDRight  { self.leftIndex = min(self.leftCount - 1, self.leftIndex + 1) }
                }
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
    @Binding var index: Int
    @Binding var photoCount: Int
    @Binding var photos: [WhatsAppMediaItem]

    @StateObject private var loader = DateCompareLoader()
    @State private var dateKey: String? = nil

    private var currentPhotos: [WhatsAppMediaItem] { loader.leftPhotos }

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
    }

    private var header: some View {
        HStack(spacing: 8) {
            // Date picker
            if contact == nil {
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
            Color.black.overlay(
                Text(dateKey == nil ? "Pick a date above" : "No photos")
                    .foregroundColor(.secondary).font(.caption)
            )
        } else if currentPhotos.indices.contains(index) {
            ZStack {
                Color.black
                if let t = currentPhotos[index].thumb {
                    Image(nsImage: t).resizable().scaledToFit()
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

// MARK: - Date Compare View

struct DateCompareView: View {
    /// Called with (lastWeekImage, thisWeekImage) when user taps "+ Add pair"
    let onAddPair: (NSImage?, NSImage?) -> Void

    @StateObject private var dcLoader = DateCompareLoader()
    @State private var leftDateKey:  String? = nil
    @State private var rightDateKey: String? = nil
    @State private var leftIndex    = 0
    @State private var rightIndex   = 0
    @State private var linkedIndex  = 0
    @State private var linked       = false
    @State private var dcKeyMonitor: Any? = nil
    @State private var dcAIMatches:  [PoseMatch] = []
    @State private var dcAIMatchIdx  = 0
    @State private var dcAILoading   = false
    @State private var dcAIError:    String? = nil

    var body: some View {
        VStack(spacing: 0) {
            contactBar
            Divider()

            if dcLoader.selectedContact == nil {
                emptyState("Select a client above to get started")
            } else if dcLoader.dates.isEmpty {
                emptyState("No photos found for this client")
            } else {
                HStack(spacing: 0) {
                    photoSide(title: "LAST WEEK",
                              dateKey: $leftDateKey,
                              photos: dcLoader.leftPhotos,
                              loading: dcLoader.isLoadingLeft,
                              index: linked ? $linkedIndex : $leftIndex,
                              side: .left)

                    Rectangle().fill(Color.white.opacity(0.2)).frame(width: 2)

                    photoSide(title: "THIS WEEK",
                              dateKey: $rightDateKey,
                              photos: dcLoader.rightPhotos,
                              loading: dcLoader.isLoadingRight,
                              index: linked ? $linkedIndex : $rightIndex,
                              side: .right)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            }

            Divider()
            addBar
        }
        .onAppear  { startDCKeyMonitor() }
        .onDisappear { stopDCKeyMonitor() }
        // Trigger loads when dates change
        .onChange(of: leftDateKey) { _, key in
            leftIndex = 0
            if let key, let contact = dcLoader.selectedContact {
                Task { await dcLoader.loadSide(.left, contact: contact, dateKey: key) }
            }
        }
        .onChange(of: rightDateKey) { _, key in
            rightIndex = 0
            if let key, let contact = dcLoader.selectedContact {
                Task { await dcLoader.loadSide(.right, contact: contact, dateKey: key) }
            }
        }
        .onChange(of: dcLoader.selectedContact) { _, contact in
            leftDateKey = nil; rightDateKey = nil
            leftIndex = 0; rightIndex = 0
            if let c = contact { Task { await dcLoader.loadDates(for: c) } }
        }
    }

    // MARK: AI helpers

    private func dcRunAI(leftURLs: [URL], rightURLs: [URL]) {
        guard !leftURLs.isEmpty, !rightURLs.isEmpty else { return }
        dcAILoading = true; dcAIError = nil; dcAIMatches = []
        Task {
            do {
                let matches   = try await AIMatchEngine.shared.matchPoses(leftURLs: leftURLs,
                                                                           rightURLs: rightURLs)
                dcAIMatches   = matches
                dcAIMatchIdx  = 0
                if let first  = matches.first {
                    leftIndex  = first.leftIndex
                    rightIndex = first.rightIndex
                }
            } catch { dcAIError = error.localizedDescription }
            dcAILoading = false
        }
    }

    private func dcStepAI(_ delta: Int) {
        let next = dcAIMatchIdx + delta
        guard dcAIMatches.indices.contains(next) else { return }
        dcAIMatchIdx = next
        leftIndex    = dcAIMatches[next].leftIndex
        rightIndex   = dcAIMatches[next].rightIndex
    }

    // MARK: Keyboard

    private func startDCKeyMonitor() {
        dcKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let isLeft  = event.keyCode == 123
            let isRight = event.keyCode == 124
            guard isLeft || isRight else { return event }
            if !self.dcAIMatches.isEmpty {
                if isLeft  { self.dcStepAI(-1) }
                if isRight { self.dcStepAI(1) }
                return nil
            }
            let lCount = self.dcLoader.leftPhotos.count
            let rCount = self.dcLoader.rightPhotos.count
            let opt    = event.modifierFlags.contains(.option)
            if self.linked {
                let cap = max(lCount, rCount)
                if isLeft  { self.linkedIndex = max(0, self.linkedIndex - 1) }
                if isRight { self.linkedIndex = min(cap - 1, self.linkedIndex + 1) }
            } else if opt {
                if isLeft  { self.rightIndex = max(0, self.rightIndex - 1) }
                if isRight { self.rightIndex = min(rCount - 1, self.rightIndex + 1) }
            } else {
                if isLeft  { self.leftIndex = max(0, self.leftIndex - 1) }
                if isRight { self.leftIndex = min(lCount - 1, self.leftIndex + 1) }
            }
            return nil
        }
    }

    private func stopDCKeyMonitor() {
        if let m = dcKeyMonitor { NSEvent.removeMonitor(m); dcKeyMonitor = nil }
    }

    // MARK: Sub-views

    private var contactBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.fill").foregroundColor(.secondary).font(.caption)

            if dcLoader.isLoadingContacts {
                ProgressView().scaleEffect(0.7)
            } else {
                Picker("Client", selection: $dcLoader.selectedContact) {
                    Text("Select client…").tag(String?.none)
                    ForEach(dcLoader.contacts) { c in
                        Text("\(c.name)  (\(c.photoCount))").tag(Optional(c.name))
                    }
                }
                .labelsHidden().frame(width: 240)
            }

            Divider().frame(height: 20)

            Toggle(isOn: $linked) {
                Label("Sync arrows", systemImage: linked ? "link" : "link.badge.plus")
                    .font(.caption)
            }
            .toggleStyle(.checkbox)
            .onChange(of: linked) { _, on in if on { linkedIndex = leftIndex } }

            Divider().frame(height: 20)

            if !dcAIMatches.isEmpty {
                HStack(spacing: 8) {
                    Button { dcStepAI(-1) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.plain).disabled(dcAIMatchIdx == 0)
                    Text("AI: \(dcAIMatches[dcAIMatchIdx].pose.capitalized)  \(dcAIMatchIdx+1)/\(dcAIMatches.count)")
                        .font(.caption.bold()).foregroundColor(.blue)
                    Button { dcStepAI(1) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(.plain).disabled(dcAIMatchIdx == dcAIMatches.count - 1)
                    Button("Clear") { dcAIMatches = []; dcAIMatchIdx = 0 }
                        .buttonStyle(.link).font(.caption)
                }
            } else if dcAILoading {
                ProgressView().scaleEffect(0.7)
                Text("Matching poses…").font(.caption).foregroundColor(.secondary)
            } else {
                Button {
                    dcRunAI(leftURLs:  dcLoader.leftPhotos.map(\.url),
                            rightURLs: dcLoader.rightPhotos.map(\.url))
                } label: {
                    Label("AI Match", systemImage: "sparkles").font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .disabled(dcLoader.leftPhotos.isEmpty || dcLoader.rightPhotos.isEmpty)
                .help("Automatically pair matching poses using AI")
            }

            if let err = dcAIError {
                Text(err).font(.caption).foregroundColor(.red).lineLimit(1)
            }

            Spacer()
            Text("Pick dates · AI Match or use arrows · tap + Add")
                .font(.caption).foregroundColor(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var addBar: some View {
        HStack(spacing: 14) {
            let leftItem  = dcLoader.leftPhotos.indices.contains(leftIndex)  ? dcLoader.leftPhotos[leftIndex]  : nil
            let rightItem = dcLoader.rightPhotos.indices.contains(rightIndex) ? dcLoader.rightPhotos[rightIndex] : nil

            Button("+ Add this pair to comparison") {
                Task.detached {
                    let l = leftItem.flatMap  { NSImage(contentsOf: $0.url) }
                    let r = rightItem.flatMap { NSImage(contentsOf: $0.url) }
                    await MainActor.run { onAddPair(l, r) }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(leftItem == nil && rightItem == nil)

            Spacer()

            Text("After adding pairs, switch to Manual mode to export the comparison")
                .font(.caption).foregroundColor(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func emptyState(_ msg: String) -> some View {
        Text(msg).foregroundColor(.secondary).font(.caption)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
    }

    // MARK: Photo side panel

    private func photoSide(title: String,
                            dateKey: Binding<String?>,
                            photos: [WhatsAppMediaItem],
                            loading: Bool,
                            index: Binding<Int>,
                            side: DateCompareLoader.Side) -> some View {
        VStack(spacing: 0) {
            // Header: label + date picker + arrows
            VStack(spacing: 6) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white.opacity(0.65))

                Picker("", selection: dateKey) {
                    Text("Pick a date…").tag(String?.none)
                    ForEach(dcLoader.dates) { d in
                        Text(d.displayString).tag(Optional(d.key))
                    }
                }
                .labelsHidden()
                .colorScheme(.dark)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)

                if !photos.isEmpty {
                    HStack(spacing: 16) {
                        Button {
                            index.wrappedValue = max(0, index.wrappedValue - 1)
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 18, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(index.wrappedValue == 0 ? .white.opacity(0.25) : .white)
                        .disabled(index.wrappedValue == 0)

                        Text("\(index.wrappedValue + 1) / \(photos.count)")
                            .font(.system(.caption, design: .monospaced).bold())
                            .foregroundColor(.white)

                        Button {
                            index.wrappedValue = min(photos.count - 1, index.wrappedValue + 1)
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 18, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(index.wrappedValue == photos.count - 1 ? .white.opacity(0.25) : .white)
                        .disabled(index.wrappedValue == photos.count - 1)
                    }
                }
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.5))

            Divider().background(Color.white.opacity(0.15))

            // Photo area
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if photos.isEmpty {
                    Color.black.overlay(
                        Text(dateKey.wrappedValue == nil ? "Pick a date above" : "No photos")
                            .foregroundColor(.secondary).font(.caption)
                    )
                } else if photos.indices.contains(index.wrappedValue) {
                    let item = photos[index.wrappedValue]
                    ZStack {
                        Color.black
                        if let t = item.thumb {
                            Image(nsImage: t)
                                .resizable()
                                .scaledToFit()
                        } else {
                            ProgressView()
                        }
                    }
                } else {
                    Color.black
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
