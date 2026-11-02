import SwiftUI
import AVKit
import AVFoundation

/// The post-recording trim editor ("chop out the fluff") — opened from the saved popup's
/// "edit video" button. Coach scrubs the recording, marks start/end around a mistake, cuts it
/// (repeatable for several mistakes), previews with cuts skipped, and saves an EDITED COPY —
/// the original is always kept. Everything runs locally on the finished file; the edited copy
/// is handed back via `onSaved` so it flows through the normal banner (WhatsApp/backup/link).
struct TrimEditorSheet: View {
    let url: URL
    let onSaved: (URL) -> Void
    @Binding var isPresented: Bool

    @State private var player = AVPlayer()
    @State private var duration: Double = 0
    @State private var currentTime: Double = 0
    @State private var timeObserver: Any?

    @State private var isPlaying = false
    @State private var selStart: Double?
    @State private var selEnd: Double?
    @State private var cuts: [ClosedRange<Double>] = []
    @State private var skipCutsWhilePlaying = true

    // "find in recording" — on-demand, on-device transcription + phrase search.
    @State private var transcript: [VideoTranscriber.Word]?
    @State private var isTranscribing = false
    @State private var transcribeProgress: Double = 0
    @State private var transcribeTask: Task<Void, Never>?
    @State private var searchText = ""
    @State private var transcriptCopied = false
    @State private var matches: [VideoTranscriber.Match] = []
    @State private var matchIndex = 0
    @State private var searchNote: String?

    @State private var isExporting = false
    @State private var exportProgress: Double = 0
    @State private var exportError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Brand.border)

            PlayerContainer(player: player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)

            VStack(spacing: 10) {
                searchRow
                timeline
                controls
                if !cuts.isEmpty { cutChips }
                if let err = exportError {
                    Text(err).font(Brand.font(12)).foregroundStyle(.orange)
                }
            }
            .padding(14)
            .background(Brand.bgElev)

            Divider().overlay(Brand.border)
            footer
        }
        .frame(width: 880, height: 640)
        .background(Brand.bg)
        .brandTheme()
        .onAppear { load(); Analytics.track("trim_opened") }
        .onDisappear { teardown() }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "scissors").font(.system(size: 16)).foregroundStyle(Brand.accent2)
            VStack(alignment: .leading, spacing: 1) {
                Text("edit video").font(Brand.font(16, .bold)).foregroundStyle(Brand.text)
                Text("mark the bit you fluffed, cut it, save — your original is kept")
                    .font(Brand.font(11)).foregroundStyle(Brand.muted)
            }
            Spacer()
            Text(url.lastPathComponent).font(Brand.font(11)).foregroundStyle(Brand.muted)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 280)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if isExporting {
                ProgressView(value: exportProgress)
                    .frame(width: 220)
                Text("saving edited copy… \(Int(exportProgress * 100))%")
                    .font(Brand.font(12)).foregroundStyle(Brand.muted)
            } else if !cuts.isEmpty {
                Text("\(cuts.count) cut\(cuts.count == 1 ? "" : "s") · removing \(timeString(cuts.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) })) · new length \(timeString(editedDuration))")
                    .font(Brand.font(12)).foregroundStyle(Brand.muted)
            }
            Spacer()
            Button("cancel") { isPresented = false }
                .buttonStyle(OutlineButtonStyle())
                .disabled(isExporting)
            Button("save edited copy") { save() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(cuts.isEmpty || isExporting)
        }
        .padding(14)
    }

    // MARK: Timeline

    private var timeline: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                // Track
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Brand.control)
                // Cut sections (red)
                ForEach(Array(cuts.enumerated()), id: \.offset) { _, cut in
                    Rectangle()
                        .fill(Brand.danger.opacity(0.55))
                        .frame(width: max(2, xFor(cut.upperBound - cut.lowerBound, in: w)))
                        .offset(x: xFor(cut.lowerBound, in: w))
                }
                // Search-match markers
                ForEach(Array(matches.enumerated()), id: \.offset) { i, m in
                    Rectangle()
                        .fill(Color.yellow.opacity(i == matchIndex ? 1 : 0.55))
                        .frame(width: 2)
                        .offset(x: xFor(m.time, in: w) - 1)
                }
                // In-progress selection (accent)
                if let s = selStart {
                    let e = selEnd ?? currentTime
                    let lo = min(s, e), hi = max(s, e)
                    Rectangle()
                        .fill(Brand.accent.opacity(0.35))
                        .overlay(Rectangle().stroke(Brand.accent, lineWidth: 1))
                        .frame(width: max(2, xFor(hi - lo, in: w)))
                        .offset(x: xFor(lo, in: w))
                }
                // Playhead
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2)
                    .offset(x: xFor(currentTime, in: w) - 1)
                    .shadow(color: .black.opacity(0.6), radius: 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                seek(to: (g.location.x / max(1, w)) * duration)
            })
        }
        .frame(height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Text("\(timeString(currentTime)) / \(timeString(duration))")
                .font(.system(.caption, design: .monospaced).bold())
                .foregroundStyle(Brand.text.opacity(0.85))
                .frame(width: 118, alignment: .leading)

            Button { nudge(-5) } label: { Image(systemName: "gobackward.5") }
                .buttonStyle(OutlineButtonStyle())
            Button { togglePlay() } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 16)
            }
            .buttonStyle(OutlineButtonStyle())
            Button { nudge(5) } label: { Image(systemName: "goforward.5") }
                .buttonStyle(OutlineButtonStyle())

            Divider().frame(height: 20)

            Button("cut from here") { selStart = currentTime; if let e = selEnd, e <= currentTime { selEnd = nil } }
                .buttonStyle(OutlineButtonStyle(active: selStart != nil))
                .help("Mark where the bit to remove STARTS (at the playhead)")
            Button("to here") { if let s = selStart, currentTime > s { selEnd = currentTime } }
                .buttonStyle(OutlineButtonStyle(active: selEnd != nil))
                .disabled(selStart == nil)
                .help("Mark where the bit to remove ENDS (at the playhead)")
            Button {
                if let s = selStart, let e = selEnd, e > s {
                    cuts.append(s...e)
                    selStart = nil; selEnd = nil
                }
            } label: {
                HStack(spacing: 5) { Image(systemName: "scissors"); Text("cut it") }
            }
            .buttonStyle(PrimaryButtonStyle(color: Brand.danger))
            .disabled(selStart == nil || selEnd == nil)

            Spacer()

            Toggle(isOn: $skipCutsWhilePlaying) {
                Text("preview with cuts").font(Brand.font(12))
            }
            .toggleStyle(.checkbox)
            .help("While playing, jump over the cut sections — hear the video as your client will")
        }
    }

    private var cutChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(cuts.enumerated()), id: \.offset) { i, cut in
                    HStack(spacing: 5) {
                        Text("\(timeString(cut.lowerBound))–\(timeString(cut.upperBound))")
                            .font(.system(.caption2, design: .monospaced))
                        Button { cuts.remove(at: i) } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Brand.danger.opacity(0.25)))
                    .overlay(Capsule().stroke(Brand.danger.opacity(0.5), lineWidth: 1))
                }
            }
        }
        .frame(height: 26)
    }

    // MARK: Find in recording

    private var searchRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 12)).foregroundStyle(Brand.muted)
            TextField("find a word or phrase — jump straight to it…", text: $searchText)
                .textFieldStyle(.plain)
                .font(Brand.font(12.5))
                .onSubmit { runSearch() }
                .frame(maxWidth: 300)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Brand.control))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Brand.controlBorder, lineWidth: 1))
            if isTranscribing {
                ProgressView(value: transcribeProgress).frame(width: 110)
                Text("transcribing on this Mac… \(Int(transcribeProgress * 100))%")
                    .font(Brand.font(11)).foregroundStyle(Brand.muted)
            } else {
                Button("find") { runSearch() }
                    .buttonStyle(OutlineButtonStyle())
                    .disabled(searchText.trimmingCharacters(in: .whitespaces).isEmpty)
                // Whole-transcript copy — for pasting the check-in into an AI summariser.
                // Reuses the same cached transcription as search; first click on an
                // untranscribed clip runs the on-device pass, then copies.
                Button(transcriptCopied ? "copied ✓" : "copy transcript") { copyTranscript() }
                    .buttonStyle(OutlineButtonStyle())
            }
            if !matches.isEmpty, matches.indices.contains(matchIndex) {
                Button { stepMatch(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain)
                Text("\(matchIndex + 1)/\(matches.count)")
                    .font(.system(.caption, design: .monospaced).bold())
                    .foregroundStyle(Brand.text.opacity(0.85))
                Button { stepMatch(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.plain)
                Text(matches[matchIndex].snippet)
                    .font(Brand.font(11)).foregroundStyle(Brand.muted)
                    .lineLimit(1).truncationMode(.tail)
            } else if let note = searchNote {
                Text(note).font(Brand.font(11)).foregroundStyle(.orange)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer()
        }
    }

    /// Copy the full transcript as plain text (transcribing first if needed — same
    /// on-device pass and cache as "find in recording").
    private func copyTranscript() {
        if let words = transcript { placeTranscriptOnClipboard(words); return }
        guard !isTranscribing else { return }
        searchNote = nil
        isTranscribing = true
        transcribeProgress = 0
        let source = url
        transcribeTask = Task {
            do {
                let words = try await VideoTranscriber.transcribe(url: source) { p in
                    Task { @MainActor in transcribeProgress = p }
                }
                transcript = words
                isTranscribing = false
                Analytics.track("transcript_copied")
                placeTranscriptOnClipboard(words)
            } catch {
                isTranscribing = false
                if !Task.isCancelled { searchNote = error.localizedDescription }
            }
        }
    }

    private func placeTranscriptOnClipboard(_ words: [VideoTranscriber.Word]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(VideoTranscriber.plainText(words), forType: .string)
        transcriptCopied = true
        Task { try? await Task.sleep(nanoseconds: 2_000_000_000)
               transcriptCopied = false }
    }

    private func runSearch() {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searchNote = nil
        if let words = transcript { applySearch(q, words); return }
        guard !isTranscribing else { return }
        isTranscribing = true
        transcribeProgress = 0
        let source = url
        transcribeTask = Task {
            do {
                let words = try await VideoTranscriber.transcribe(url: source) { p in
                    Task { @MainActor in transcribeProgress = p }
                }
                transcript = words
                isTranscribing = false
                Analytics.track("transcribe_search")
                applySearch(q, words)
            } catch {
                isTranscribing = false
                if !Task.isCancelled { searchNote = error.localizedDescription }
            }
        }
    }

    private func applySearch(_ q: String, _ words: [VideoTranscriber.Word]) {
        matches = VideoTranscriber.search(q, in: words)
        matchIndex = 0
        if matches.isEmpty {
            searchNote = "\"\(q)\" not found in this recording"
        } else {
            searchNote = nil
            jumpToCurrentMatch()
        }
    }

    private func stepMatch(_ delta: Int) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + delta + matches.count) % matches.count
        jumpToCurrentMatch()
    }

    /// Land a beat BEFORE the phrase so the coach hears it in context.
    private func jumpToCurrentMatch() {
        guard matches.indices.contains(matchIndex) else { return }
        seek(to: max(0, matches[matchIndex].time - 0.75))
    }

    // MARK: Logic

    private var editedDuration: Double {
        VideoTrimmer.keptRanges(duration: duration, cuts: cuts)
            .reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
    }

    private func xFor(_ seconds: Double, in width: CGFloat) -> CGFloat {
        duration > 0 ? CGFloat(seconds / duration) * width : 0
    }

    private func timeString(_ t: Double) -> String {
        let s = Int(max(0, t).rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func load() {
        transcript = VideoTranscriber.cachedTranscript(for: url)
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        Task {
            if let d = try? await AVURLAsset(url: url).load(.duration).seconds { duration = d }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main) { t in
            currentTime = t.seconds
            isPlaying = player.timeControlStatus == .playing
            // "Preview with cuts": while playing, hop over any cut section.
            if skipCutsWhilePlaying, player.timeControlStatus == .playing,
               let hit = cuts.first(where: { $0.contains(t.seconds) }) {
                player.seek(to: CMTime(seconds: hit.upperBound, preferredTimescale: 600),
                            toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
    }

    private func teardown() {
        transcribeTask?.cancel()
        if let obs = timeObserver { player.removeTimeObserver(obs); timeObserver = nil }
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    private func seek(to seconds: Double) {
        let t = min(max(0, seconds), duration)
        currentTime = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func nudge(_ delta: Double) { seek(to: currentTime + delta) }

    private func togglePlay() {
        player.timeControlStatus == .playing ? player.pause() : player.play()
    }

    private func save() {
        isExporting = true
        exportProgress = 0
        exportError = nil
        player.pause()
        let dest = VideoTrimmer.editedOutputURL(for: url)
        let cutsSnapshot = cuts
        let source = url
        Task {
            do {
                try await VideoTrimmer.export(source: source, cuts: cutsSnapshot, to: dest) { p in
                    Task { @MainActor in exportProgress = p }
                }
                isExporting = false
                Analytics.track("trim_saved", ["cuts": cutsSnapshot.count])
                onSaved(dest)
                isPresented = false
            } catch {
                isExporting = false
                exportError = error.localizedDescription
                RecordingSession.appendErrorLog("trim export failed: \(error.localizedDescription)")
            }
        }
    }
}

/// AppKit-backed player surface. SwiftUI's own `VideoPlayer` (the _AVKit_SwiftUI overlay)
/// crashes at metadata instantiation on macOS the moment it's built — a known-flaky wrapper —
/// so we host AVKit's AVPlayerView directly. Controls are ours (the timeline below), so the
/// native chrome is switched off.
private struct PlayerContainer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        v.showsFullScreenToggleButton = false
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
    }
}

// MARK: - Compact transcript-copy button (saved banner)

/// Icon-only "copy transcript" for the saved popup — same on-device transcription + cache as
/// the trim editor's search, so whichever runs first pays the cost and the other is instant.
/// Lets a coach paste the whole check-in into their notes or an AI summariser without opening
/// the editor. Icon-only because the 430pt banner row is full.
struct TranscriptCopyButton: View {
    let url: URL
    @State private var working = false
    @State private var progress: Double = 0
    @State private var copied = false
    @State private var errorNote: String?

    var body: some View {
        Button { copyTranscript() } label: {
            if working {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text("\(Int(progress * 100))%").font(Brand.font(11))
                }
            } else {
                Text(copied ? "copied ✓" : "copy transcript")
            }
        }
        .buttonStyle(OutlineButtonStyle())
        .disabled(working)
        .help(errorNote ?? "copy everything said in this recording as text — paste into your notes or an AI for a client summary. transcribed on this mac; audio never leaves it.")
    }

    private func copyTranscript() {
        if let words = VideoTranscriber.cachedTranscript(for: url) { place(words); return }
        working = true
        progress = 0
        let source = url
        Task {
            do {
                let words = try await VideoTranscriber.transcribe(url: source) { p in
                    Task { @MainActor in progress = p }
                }
                working = false
                Analytics.track("transcript_copied")
                place(words)
            } catch {
                working = false
                errorNote = error.localizedDescription
            }
        }
    }

    private func place(_ words: [VideoTranscriber.Word]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(VideoTranscriber.plainText(words), forType: .string)
        copied = true
        Task { try? await Task.sleep(nanoseconds: 2_000_000_000); copied = false }
    }
}
