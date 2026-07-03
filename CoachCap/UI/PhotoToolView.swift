import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Model

struct ImagePair: Identifiable {
    let id   = UUID()
    var label: String    = ""
    var before: NSImage? = nil
    var after:  NSImage? = nil
}

// MARK: - Main View

struct PhotoToolView: View {
    enum ViewMode { case manual, dateCompare, browse }

    @State private var pairs: [ImagePair]  = [ImagePair()]
    @State private var current: Int        = 0
    @State private var showHeaders         = true
    @State private var isSaving            = false
    @State private var savedURL: URL?      = nil
    @State private var errorMsg: String?   = nil
    @State private var showWhatsApp        = true
    @State private var viewMode: ViewMode  = .browse   // open on smart match
    @State private var exportClientName    = ""
    @State private var annotationImage:    NSImage? = nil
    @State private var showAnnotation      = false
    @ObservedObject private var licenseManager = LicenseManager.shared
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            navBar
            if viewMode == .dateCompare {
                DateCompareView { before, after in
                    pairs.append(ImagePair(before: before, after: after))
                    current = pairs.count - 1
                }
            } else if viewMode == .browse {
                BrowseView()
            } else {
                viewer
                thumbnailStrip
                whatsAppSection
                controlsBar
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .background(Brand.bg)
        .sheet(isPresented: $showAnnotation) {
            if let img = annotationImage {
                AnnotationView(
                    image: img,
                    suggestedFilename: savedURL.map {
                        $0.deletingPathExtension().lastPathComponent + "_annotated.jpg"
                    } ?? "comparison_annotated.jpg"
                )
            }
        }
    }

    // MARK: WhatsApp strip

    private var whatsAppSection: some View {
        VStack(spacing: 0) {
            // Toggle header
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showWhatsApp.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "message.fill")
                        .foregroundColor(Color(hex: 0x28C840))
                        .font(.system(size: 11))
                    Text("from whatsapp")
                        .font(Brand.font(13, .semibold))
                        .foregroundStyle(Brand.text)
                    Text("· hover a photo, tap lw or tw to assign")
                        .font(Brand.font(12))
                        .foregroundStyle(Brand.muted)
                    Spacer()
                    Image(systemName: showWhatsApp ? "chevron.up" : "chevron.down")
                        .foregroundStyle(Brand.muted)
                        .font(.caption)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showWhatsApp {
                Divider().overlay(Brand.border)
                WhatsAppMediaBrowser { image, slot in
                    switch slot {
                    case .lastWeek: pairs[current].before = image
                    case .thisWeek: pairs[current].after  = image
                    }
                }
            }
        }
        .background(Brand.bgElev)
    }

    // MARK: Nav bar

    private var navBar: some View {
        HStack(spacing: 14) {
            Button(action: prev) {
                Image(systemName: "chevron.left")
            }
            .disabled(current == 0)
            .buttonStyle(.borderless)

            Text("pose \(current + 1) of \(pairs.count)")
                .font(Brand.font(13, .semibold))
                .foregroundStyle(Brand.text)
                .frame(minWidth: 90)

            Button(action: next) {
                Image(systemName: "chevron.right")
            }
            .disabled(current == pairs.count - 1)
            .buttonStyle(.borderless)

            Spacer()

            // Auto-hide toggle — same setting as the recorder's, surfaced here so the coach
            // can flip it without leaving the before/after screen. OFF keeps the window (and
            // the photos being explained) on screen when recording over the float cam.
            autoHideToggle

            // Mode toggle — shared segmented control
            BrandSegmented(selection: $viewMode, options: [
                ("smart match", ViewMode.browse),
                ("by date",     ViewMode.dateCompare),
                ("paste",       ViewMode.manual)
            ], compact: true, recommended: ViewMode.browse)
            .frame(width: 320)

            Button("+ add pose") {
                pairs.append(ImagePair())
                current = pairs.count - 1
            }
            .buttonStyle(PrimaryButtonStyle())
            .opacity(viewMode == .dateCompare ? 0 : 1)
            .disabled(viewMode == .dateCompare)

            if pairs.count > 1 {
                Button("remove") {
                    pairs.remove(at: current)
                    current = min(current, pairs.count - 1)
                }
                .foregroundStyle(Brand.danger)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(Brand.bgElev)
        .overlay(Rectangle().fill(Brand.border).frame(height: 1), alignment: .bottom)
    }

    private var autoHideToggle: some View {
        let active = appState.hideWindowWhileRecordingBeforeAfter
        return Button {
            // Don't change it mid-recording — the next recording reads the live value.
            // This is the before/after screen's own auto-hide setting (defaults off).
            if !appState.isRecording { appState.hideWindowWhileRecordingBeforeAfter.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "macwindow").font(.system(size: 12))
                Text("auto-hide").font(Brand.font(12, active ? .semibold : .medium))
            }
            .foregroundStyle(active ? Brand.text : Brand.muted)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(active ? Brand.control : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Brand.controlBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(appState.isRecording)
        .help("Minimise the CoachCam window when recording starts. Leave OFF while explaining before/after photos so they stay on screen; turn ON to talk over Google Sheets etc.")
    }

    // MARK: Main viewer (before | after, full height, zoomable)

    private var viewer: some View {
        HStack(spacing: 0) {
            // Prev arrow overlay
            Button(action: prev) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 28, weight: .light))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.black.opacity(0.35))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 10)
            .opacity(current > 0 ? 1 : 0)

            Spacer(minLength: 0)

            // Before panel
            ZStack(alignment: .top) {
                PhotoPanel(image: $pairs[current].before)
                Text("last week")
                    .font(Brand.font(12, .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(Color.black.opacity(0.45)))
                    .padding(.top, 10)
            }

            // Divider
            Rectangle()
                .fill(Color.white.opacity(0.25))
                .frame(width: 2)

            // After panel
            ZStack(alignment: .top) {
                PhotoPanel(image: $pairs[current].after)
                Text("this week")
                    .font(Brand.font(12, .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(Color.black.opacity(0.45)))
                    .padding(.top, 10)
            }

            Spacer(minLength: 0)

            // Next arrow overlay
            Button(action: next) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 28, weight: .light))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.black.opacity(0.35))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 10)
            .opacity(current < pairs.count - 1 ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.bg)
    }

    // MARK: Thumbnail strip

    private var thumbnailStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pairs.indices, id: \.self) { i in
                    PoseThumbnail(pair: pairs[i], isSelected: i == current)
                        .onTapGesture { current = i }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(height: 72)
        .background(Brand.bgElev)
    }

    // MARK: Controls bar

    private var controlsBar: some View {
        HStack(spacing: 14) {
            TextField("client name (optional)", text: $exportClientName)
                .textFieldStyle(.plain)
                .font(Brand.font(13))
                .foregroundStyle(Brand.text)
                .frame(width: 200)
                .brandPill(height: 34)

            Toggle("column headers in export", isOn: $showHeaders)
                .toggleStyle(.checkbox)
                .font(Brand.font(12))

            Spacer()

            if let url = savedURL {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text(url.lastPathComponent).font(.caption).lineLimit(1)
                    Button("reveal") { ExportManager.revealInFinder(url) }
                        .buttonStyle(LinkButtonStyle())
                    Button("copy") { copyToClipboard() }
                        .buttonStyle(LinkButtonStyle())
                    if annotationImage != nil {
                        Button("annotate") { showAnnotation = true }
                            .buttonStyle(LinkButtonStyle())
                    }
                }
            }

            if let err = errorMsg {
                Text(err).foregroundStyle(Brand.danger).font(Brand.font(12))
            }

            Button(isSaving ? "saving…" : "save jpeg") { save() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!hasImages || isSaving)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .overlay(Rectangle().fill(Brand.border).frame(height: 1), alignment: .top)
    }

    // MARK: Helpers

    private var hasImages: Bool { pairs.contains { $0.before != nil || $0.after != nil } }

    private func prev() { if current > 0 { current -= 1 } }
    private func next() { if current < pairs.count - 1 { current += 1 } }

    private func save() {
        isSaving = true; errorMsg = nil
        let opts      = makeOptions()
        let pairsSnap = pairs.map { ($0.before, $0.after) }
        let isPaid    = licenseManager.isUnlocked   // single licence source
        Task.detached(priority: .userInitiated) {
            do {
                guard var img = PhotoStitcher.stitch(pairs: pairsSnap, options: opts) else {
                    throw StitchError.renderFailed
                }
                // Free tier: watermark the comparison (same function as the preview).
                if !isPaid { img = WatermarkRenderer.apply(to: img) }
                let url = PhotoStitcher.autoOutputURL()
                try PhotoStitcher.exportJPEG(img, to: url)
                await MainActor.run { savedURL = url; annotationImage = img; isSaving = false }
                ExportManager.revealInFinder(url)
            } catch {
                await MainActor.run { errorMsg = error.localizedDescription; isSaving = false }
            }
        }
    }

    private func copyToClipboard() {
        guard let url = savedURL, let img = NSImage(contentsOf: url) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
    }

    private func makeOptions() -> PhotoStitcher.Options {
        var o = PhotoStitcher.Options()
        o.showColumnHeaders = showHeaders
        o.clientName = exportClientName.trimmingCharacters(in: .whitespaces)
        return o
    }
}

// MARK: - Photo Panel (drop zone OR zoomable image)

private struct PhotoPanel: View {
    @Binding var image: NSImage?
    @State private var isTargeted = false
    // The preview shows the watermarked image (free) via the SAME function as the export,
    // so what the coach sees matches the client's copy and a screenshot can't bypass it.
    @ObservedObject private var license = LicenseManager.shared
    @State private var displayImage: NSImage?

    private func updateDisplay() {
        guard let img = image else { displayImage = nil; return }
        displayImage = license.isUnlocked ? img : WatermarkRenderer.apply(to: img)
    }

    var body: some View {
        ZStack {
            if image != nil {
                ZoomablePhoto { Image(nsImage: displayImage ?? image!).resizable().scaledToFit() }
                    .id(ObjectIdentifier(displayImage ?? image!))   // reset zoom when the photo changes
                    .overlay(alignment: .topTrailing) {
                        Button { image = nil } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.white.opacity(0.8))
                                .background(Color.black.opacity(0.3))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                    }
            } else {
                dropPlaceholder
            }
        }
        .onAppear { updateDisplay() }
        .onChange(of: image) { _, _ in updateDisplay() }
        .onChange(of: license.isUnlocked) { _, _ in updateDisplay() }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.bg)
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(isTargeted ? Color.accentColor : Color.clear, lineWidth: 3)
        )
        .onDrop(of: [.fileURL, .image, .png, .jpeg, .tiff], isTargeted: $isTargeted) { providers in
            guard let p = providers.first else { return false }
            load(from: p); return true
        }
    }

    private var dropPlaceholder: some View {
        ZStack {
            VStack(spacing: 16) {
                BrandEmptyState(icon: "photo.badge.arrow.down",
                                title: "drop from whatsapp",
                                subtitle: "or click to browse")
                Button("paste") { pasteFromClipboard() }
                    .buttonStyle(LinkButtonStyle())
            }
            .padding(30)
            .frame(maxWidth: 300)
            .background(RoundedRectangle(cornerRadius: Brand.rPanel, style: .continuous)
                .fill(Color.white.opacity(0.02)))
            .overlay(RoundedRectangle(cornerRadius: Brand.rPanel, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .foregroundStyle(isTargeted ? Brand.accent : Brand.controlBorder))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
        .contentShape(Rectangle())
        .onTapGesture { browse() }
    }

    private func load(from provider: NSItemProvider) {
        if provider.hasItemConformingToTypeIdentifier("public.file-url") {
            provider.loadItem(forTypeIdentifier: "public.file-url") { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil),
                   let img = NSImage(contentsOf: url) {
                    DispatchQueue.main.async { self.image = img }
                }
            }
            return
        }
        for uti in ["public.png", "public.jpeg", "public.tiff", "public.image"] {
            if provider.hasItemConformingToTypeIdentifier(uti) {
                provider.loadDataRepresentation(forTypeIdentifier: uti) { data, _ in
                    if let data, let img = NSImage(data: data) {
                        DispatchQueue.main.async { self.image = img }
                    }
                }
                return
            }
        }
    }

    private func pasteFromClipboard() {
        if let img = NSImage(pasteboard: NSPasteboard.general) { image = img }
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            image = NSImage(contentsOf: url)
        }
    }
}

// MARK: - Pose Thumbnail

private struct PoseThumbnail: View {
    let pair: ImagePair
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 1) {
                thumb(pair.before)
                thumb(pair.after)
            }
            .frame(width: 80, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .stroke(isSelected ? Brand.accent : Color.clear, lineWidth: 2))

            if !pair.label.isEmpty {
                Text(pair.label)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func thumb(_ img: NSImage?) -> some View {
        if let img {
            Image(nsImage: img).resizable().scaledToFill()
                .frame(width: 40, height: 48).clipped()
        } else {
            Rectangle().fill(Color.secondary.opacity(0.15))
                .frame(width: 40, height: 48)
        }
    }
}

