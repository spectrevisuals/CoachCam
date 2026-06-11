import AppKit
import Foundation

/// Stitches multiple before/after image pairs into one vertical comparison JPEG.
///
/// Layout (example — 3 poses):
///   ┌──────────┬─┬──────────┐
///   │  BEFORE  │ │  AFTER   │  ← optional column headers
///   ├──────────┼─┼──────────┤
///   │ Front B  │ │ Front A  │
///   ├──────────┴─┴──────────┤  ← thin row separator
///   │ Side B   │ │ Side A   │
///   ├──────────┴─┴──────────┤
///   │ Rear B   │ │ Rear A   │
///   └──────────────────────┘
struct PhotoStitcher {

    struct Options {
        var colDividerWidth: CGFloat  = 5
        var rowDividerHeight: CGFloat = 3
        var dividerColor: NSColor     = NSColor(white: 1, alpha: 0.85)
        var rowDividerColor: NSColor  = NSColor(white: 0.3, alpha: 1)
        var rowHeight: CGFloat        = 520
        var showColumnHeaders: Bool   = true
        var headerHeight: CGFloat     = 64
        var headerFont: NSFont        = .systemFont(ofSize: 30, weight: .semibold)
        var headerColor: NSColor      = .white
        var headerBackground: NSColor = NSColor(white: 0.08, alpha: 1)
        var jpegQuality: CGFloat      = 0.88
        // Optional client name banner at the very top
        var clientName: String        = ""
        var clientNameHeight: CGFloat = 52
        var clientNameFont: NSFont    = .systemFont(ofSize: 26, weight: .bold)
    }

    // MARK: - Public

    /// Stitches an array of (before, after) pairs.
    /// Pass nil for either image in a pair to show a grey placeholder.
    static func stitch(
        pairs: [(before: NSImage?, after: NSImage?)],
        options: Options = Options()
    ) -> NSImage? {
        let valid = pairs.filter { $0.before != nil || $0.after != nil }
        guard !valid.isEmpty else { return nil }

        // Build each row at a fixed height
        let rows: [NSImage] = valid.map { pair in
            let L = pair.before ?? placeholder(height: options.rowHeight)
            let R = pair.after  ?? placeholder(height: options.rowHeight)
            return row(left: L, right: R, options: options)
        }

        let maxW  = rows.map { $0.size.width }.max() ?? 0
        let rowSep = options.rowDividerHeight
        let headerH: CGFloat = options.showColumnHeaders ? options.headerHeight : 0
        let clientH: CGFloat = options.clientName.isEmpty ? 0 : options.clientNameHeight
        let totalH = clientH + headerH
            + rows.reduce(0) { $0 + $1.size.height }
            + rowSep * CGFloat(max(0, rows.count - 1))

        guard let canvas = makeCanvas(width: maxW, height: totalH) else { return nil }

        canvas.lockFocus()
        defer { canvas.unlockFocus() }

        // Draw from top (NSImage Y is bottom-up, so track currentY from top)
        var y = totalH

        // Client name banner
        if !options.clientName.isEmpty {
            y -= clientH
            options.headerBackground.setFill()
            NSRect(x: 0, y: y, width: maxW, height: clientH).fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: options.clientNameFont,
                .foregroundColor: options.headerColor
            ]
            let str = options.clientName as NSString
            let sz  = str.size(withAttributes: attrs)
            str.draw(at: CGPoint(x: (maxW - sz.width) / 2,
                                 y: y + (clientH - sz.height) / 2),
                     withAttributes: attrs)
        }

        // Column headers
        if options.showColumnHeaders {
            y -= headerH
            drawColumnHeaders(at: y, width: maxW, height: headerH,
                              rowWidth: rows.first?.size.width ?? maxW,
                              options: options)
        }

        // Pose rows
        for (i, rowImg) in rows.enumerated() {
            y -= rowImg.size.height
            let x = (maxW - rowImg.size.width) / 2
            rowImg.draw(in: NSRect(x: x, y: y, width: rowImg.size.width, height: rowImg.size.height))

            if i < rows.count - 1 {
                y -= rowSep
                options.rowDividerColor.setFill()
                NSRect(x: 0, y: y, width: maxW, height: rowSep).fill()
            }
        }

        return canvas
    }

    static func exportJPEG(_ image: NSImage, to url: URL, quality: CGFloat = 0.88) throws {
        guard let tiff   = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data   = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality])
        else { throw StitchError.renderFailed }
        try data.write(to: url)
    }

    static func autoOutputURL() -> URL {
        let dir = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("CoachCap", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        var url = dir.appendingPathComponent("comparison_\(df.string(from: .init()))").appendingPathExtension("jpg")
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("comparison_\(df.string(from: .init()))_\(n)").appendingPathExtension("jpg")
            n += 1
        }
        return url
    }

    // MARK: - Private helpers

    private static func row(left: NSImage, right: NSImage, options: Options) -> NSImage {
        let L = scaled(left,  toHeight: options.rowHeight)
        let R = scaled(right, toHeight: options.rowHeight)
        let w = L.size.width + options.colDividerWidth + R.size.width
        let h = options.rowHeight

        guard let img = makeCanvas(width: w, height: h) else { return left }
        img.lockFocus()
        L.draw(in: NSRect(x: 0, y: 0, width: L.size.width, height: h))
        options.dividerColor.setFill()
        NSRect(x: L.size.width, y: 0, width: options.colDividerWidth, height: h).fill()
        R.draw(in: NSRect(x: L.size.width + options.colDividerWidth, y: 0,
                          width: R.size.width, height: h))
        img.unlockFocus()
        return img
    }

    private static func drawColumnHeaders(at y: CGFloat,
                                           width: CGFloat,
                                           height: CGFloat,
                                           rowWidth: CGFloat,
                                           options: Options) {
        options.headerBackground.setFill()
        NSRect(x: 0, y: y, width: width, height: height).fill()

        let halfW = (rowWidth - options.colDividerWidth) / 2
        let attrs: [NSAttributedString.Key: Any] = [
            .font: options.headerFont,
            .foregroundColor: options.headerColor,
        ]

        func drawCentred(_ text: String, in rect: NSRect) {
            let size = text.size(withAttributes: attrs)
            let tx = rect.minX + (rect.width  - size.width)  / 2
            let ty = rect.minY + (rect.height - size.height) / 2
            text.draw(at: CGPoint(x: tx, y: ty), withAttributes: attrs)
        }

        drawCentred("LAST WEEK", in: NSRect(x: (width - rowWidth) / 2,
                                             y: y, width: halfW, height: height))
        drawCentred("THIS WEEK", in: NSRect(x: (width - rowWidth) / 2 + halfW + options.colDividerWidth,
                                             y: y, width: halfW, height: height))
    }

    private static func scaled(_ img: NSImage, toHeight h: CGFloat) -> NSImage {
        let scale = h / img.size.height
        let size  = CGSize(width: img.size.width * scale, height: h)
        let out   = NSImage(size: size)
        out.lockFocus(); img.draw(in: NSRect(origin: .zero, size: size)); out.unlockFocus()
        return out
    }

    private static func placeholder(height: CGFloat) -> NSImage {
        let size = CGSize(width: height * 0.75, height: height)
        let img  = NSImage(size: size)
        img.lockFocus()
        NSColor(white: 0.18, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        img.unlockFocus()
        return img
    }

    private static func makeCanvas(width: CGFloat, height: CGFloat) -> NSImage? {
        guard width > 0, height > 0 else { return nil }
        return NSImage(size: CGSize(width: width, height: height))
    }
}

enum StitchError: LocalizedError {
    case renderFailed
    var errorDescription: String? { "Failed to render the comparison image." }
}
