import AppKit
import SwiftUI

// MARK: - Model

struct Stroke: Identifiable {
    let id    = UUID()
    var points: [CGPoint]
    var color:  Color
    var width:  CGFloat
}

// MARK: - View

struct AnnotationView: View {
    let image: NSImage
    let suggestedFilename: String
    @Environment(\.dismiss) private var dismiss

    @State private var strokes:       [Stroke] = []
    @State private var activeStroke:  Stroke?  = nil
    @State private var strokeColor:   Color    = .red
    @State private var strokeWidth:   CGFloat  = 4
    @State private var canvasSize:    CGSize   = .zero
    @State private var savedURL:      URL?     = nil

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            drawingArea
            Divider()
            bottomBar
        }
        .frame(minWidth: 700, minHeight: 500)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 16) {
            ColorPicker("", selection: $strokeColor).labelsHidden().frame(width: 36)

            HStack(spacing: 6) {
                Image(systemName: "scribble").foregroundColor(.secondary).font(.caption)
                Slider(value: $strokeWidth, in: 2...20).frame(width: 100)
                Text(String(format: "%.0f", strokeWidth))
                    .font(.caption.monospacedDigit()).foregroundColor(.secondary).frame(width: 20)
            }

            Divider().frame(height: 20)

            Button("Undo") { if !strokes.isEmpty { strokes.removeLast() } }
                .disabled(strokes.isEmpty)
                .keyboardShortcut("z")

            Button("Clear all") { strokes = [] }
                .foregroundColor(.red)
                .disabled(strokes.isEmpty)

            Spacer()

            if let url = savedURL {
                Label(url.lastPathComponent, systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green).font(.caption)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: Drawing area

    private var drawingArea: some View {
        GeometryReader { geo in
            ZStack {
                Color.black

                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)

                // Committed strokes
                Canvas { ctx, size in
                    for stroke in strokes {
                        drawStroke(stroke, in: ctx, size: size)
                    }
                }

                // Live stroke
                Canvas { ctx, size in
                    if let s = activeStroke { drawStroke(s, in: ctx, size: size) }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { val in
                        if activeStroke == nil {
                            activeStroke = Stroke(points: [val.location],
                                                  color: strokeColor,
                                                  width: strokeWidth)
                        } else {
                            activeStroke?.points.append(val.location)
                        }
                    }
                    .onEnded { val in
                        if var s = activeStroke {
                            s.points.append(val.location)
                            strokes.append(s)
                        }
                        activeStroke = nil
                    }
            )
            .onAppear { canvasSize = geo.size }
            .onChange(of: geo.size) { _, s in canvasSize = s }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cursor(.crosshair)
    }

    private func drawStroke(_ stroke: Stroke, in ctx: GraphicsContext, size: CGSize) {
        guard stroke.points.count > 1 else { return }
        var path = Path()
        path.move(to: stroke.points[0])
        for pt in stroke.points.dropFirst() { path.addLine(to: pt) }
        ctx.stroke(path, with: .color(stroke.color),
                   style: StrokeStyle(lineWidth: stroke.width, lineCap: .round, lineJoin: .round))
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 14) {
            Button("Cancel") { dismiss() }

            Spacer()

            Button("Save Annotated JPEG") { save() }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: Export

    private func save() {
        guard let flat = render() else { return }
        let dir = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("CoachCap", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(suggestedFilename)
        if let tiff   = flat.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let data   = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.88]) {
            try? data.write(to: url)
            savedURL = url
            ExportManager.revealInFinder(url)
        }
    }

    /// Composite the base image and all drawn strokes into a single NSImage at image resolution.
    private func render() -> NSImage? {
        let imgSize = image.size
        guard imgSize.width > 0, imgSize.height > 0, canvasSize.width > 0 else { return nil }

        // Compute where scaledToFit places the image within canvasSize
        let scaleX = canvasSize.width  / imgSize.width
        let scaleY = canvasSize.height / imgSize.height
        let scale  = min(scaleX, scaleY)
        let renderedW = imgSize.width  * scale
        let renderedH = imgSize.height * scale
        let offsetX   = (canvasSize.width  - renderedW) / 2
        let offsetY   = (canvasSize.height - renderedH) / 2

        let result = NSImage(size: imgSize)
        result.lockFocus()
        defer { result.unlockFocus() }

        // Draw base image
        image.draw(in: NSRect(origin: .zero, size: imgSize))

        // Draw strokes scaled from canvas coords to image coords
        for stroke in strokes {
            let path = NSBezierPath()
            path.lineCapStyle  = .round
            path.lineJoinStyle = .round
            path.lineWidth     = stroke.width / scale

            let pts = stroke.points.compactMap { pt -> CGPoint? in
                // Remove points outside the image rect
                let ix = (pt.x - offsetX) / scale
                // SwiftUI y=0 at top; NSImage y=0 at bottom
                let iy = imgSize.height - (pt.y - offsetY) / scale
                return CGPoint(x: ix, y: iy)
            }
            guard let first = pts.first else { continue }
            path.move(to: first)
            pts.dropFirst().forEach { path.line(to: $0) }

            NSColor(stroke.color).setStroke()
            path.stroke()
        }

        return result
    }
}

// MARK: - Cursor helper

private extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        self.onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }
}
