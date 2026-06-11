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
    @State private var viewMode: ViewMode  = .manual
    @State private var exportClientName    = ""
    @State private var annotationImage:    NSImage? = nil
    @State private var showAnnotation      = false

    var body: some View {
        VStack(spacing: 0) {
            navBar
            Divider()
            if viewMode == .dateCompare {
                DateCompareView { before, after in
                    pairs.append(ImagePair(before: before, after: after))
                    current = pairs.count - 1
                }
            } else if viewMode == .browse {
                BrowseView()
            } else {
                viewer
                Divider()
                thumbnailStrip
                Divider()
                whatsAppSection
                Divider()
                controlsBar
            }
        }
        .frame(minWidth: 800, minHeight: 520)
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
                        .foregroundColor(.green)
                        .font(.system(size: 11))
                    Text("From WhatsApp")
                        .font(.subheadline.weight(.medium))
                    Text("· hover a photo, tap LW or TW to assign")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Image(systemName: showWhatsApp ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showWhatsApp {
                Divider()
                WhatsAppMediaBrowser { image, slot in
                    switch slot {
                    case .lastWeek: pairs[current].before = image
                    case .thisWeek: pairs[current].after  = image
                    }
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: Nav bar

    private var navBar: some View {
        HStack(spacing: 14) {
            Button(action: prev) {
                Image(systemName: "chevron.left")
            }
            .disabled(current == 0)
            .buttonStyle(.borderless)

            Text("Pose \(current + 1) of \(pairs.count)")
                .font(.subheadline.weight(.medium))
                .frame(minWidth: 90)

            Button(action: next) {
                Image(systemName: "chevron.right")
            }
            .disabled(current == pairs.count - 1)
            .buttonStyle(.borderless)

            TextField("Label (e.g. Front, Side, Rear)", text: labelBinding)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)

            Spacer()

            Divider().frame(height: 20)

            // Mode toggle
            Picker("Mode", selection: $viewMode) {
                Text("Manual").tag(ViewMode.manual)
                Text("Compare").tag(ViewMode.dateCompare)
                Text("Browse").tag(ViewMode.browse)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            .labelsHidden()

            Divider().frame(height: 20)

            Button("+ Add Pose") {
                pairs.append(ImagePair())
                current = pairs.count - 1
            }
            .opacity(viewMode == .dateCompare ? 0 : 1)
            .disabled(viewMode == .dateCompare)

            if pairs.count > 1 {
                Button("Remove") {
                    pairs.remove(at: current)
                    current = min(current, pairs.count - 1)
                }
                .foregroundColor(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
                Text("LAST WEEK")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white.opacity(0.75))
                    .padding(.top, 8)
            }

            // Divider
            Rectangle()
                .fill(Color.white.opacity(0.25))
                .frame(width: 2)

            // After panel
            ZStack(alignment: .top) {
                PhotoPanel(image: $pairs[current].after)
                Text("THIS WEEK")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white.opacity(0.75))
                    .padding(.top, 8)
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
        .background(Color.black)
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
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: Controls bar

    private var controlsBar: some View {
        HStack(spacing: 14) {
            TextField("Client name (optional)", text: $exportClientName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)

            Toggle("Column headers in export", isOn: $showHeaders)
                .toggleStyle(.checkbox)

            Spacer()

            if let url = savedURL {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text(url.lastPathComponent).font(.caption).lineLimit(1)
                    Button("Reveal") { ExportManager.revealInFinder(url) }
                        .buttonStyle(.link).font(.caption)
                    Button("Copy") { copyToClipboard() }
                        .buttonStyle(.link).font(.caption)
                    if annotationImage != nil {
                        Button("Annotate") { showAnnotation = true }
                            .buttonStyle(.link).font(.caption)
                    }
                }
            }

            if let err = errorMsg {
                Text(err).foregroundColor(.red).font(.caption)
            }

            Button(isSaving ? "Saving…" : "Save JPEG") { save() }
                .buttonStyle(ExportButtonStyle())
                .disabled(!hasImages || isSaving)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Helpers

    private var hasImages: Bool { pairs.contains { $0.before != nil || $0.after != nil } }

    private var labelBinding: Binding<String> {
        Binding(get: { pairs[current].label },
                set: { pairs[current].label = $0 })
    }

    private func prev() { if current > 0 { current -= 1 } }
    private func next() { if current < pairs.count - 1 { current += 1 } }

    private func save() {
        isSaving = true; errorMsg = nil
        let opts      = makeOptions()
        let pairsSnap = pairs.map { ($0.before, $0.after) }
        Task.detached(priority: .userInitiated) {
            do {
                guard let img = PhotoStitcher.stitch(pairs: pairsSnap, options: opts) else {
                    throw StitchError.renderFailed
                }
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

    var body: some View {
        ZStack {
            if let img = image {
                ZoomablePhoto(image: img)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
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
        VStack(spacing: 10) {
            Image(systemName: "photo")
                .font(.system(size: 36))
                .foregroundColor(.white.opacity(0.3))
            Text("Drop from WhatsApp\nor click to browse")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundColor(.white.opacity(0.4))
            Button("Paste") { pasteFromClipboard() }
                .font(.caption)
                .buttonStyle(.link)
                .foregroundColor(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

// MARK: - Zoomable Photo

private struct ZoomablePhoto: View {
    let image: NSImage

    @State private var zoom: CGFloat           = 1
    @State private var offset: CGSize          = .zero
    @GestureState private var liveZoom: CGFloat = 1
    @GestureState private var liveDrag: CGSize  = .zero

    var body: some View {
        GeometryReader { geo in
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(zoom * liveZoom, anchor: .center)
                .offset(x: offset.width  + liveDrag.width,
                        y: offset.height + liveDrag.height)
                .gesture(
                    MagnificationGesture()
                        .updating($liveZoom)  { v, s, _ in s = v }
                        .onEnded { v in
                            zoom = max(1, zoom * v)
                            if zoom <= 1 { zoom = 1; offset = .zero }
                        }
                )
                .gesture(
                    DragGesture()
                        .updating($liveDrag) { v, s, _ in s = v.translation }
                        .onEnded { v in
                            offset = CGSize(width:  offset.width  + v.translation.width,
                                           height: offset.height + v.translation.height)
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.spring()) { zoom = zoom > 1 ? 1 : 2; offset = .zero }
                }
        }
        .clipped()
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
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2))

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

// MARK: - Button Style

private struct ExportButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 18).padding(.vertical, 8)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.7 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}
