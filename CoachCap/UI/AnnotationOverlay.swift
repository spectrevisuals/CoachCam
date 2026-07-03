import AppKit

/// A transparent, full-screen draw layer the coach can toggle on to draw lines over ANYTHING on
/// screen (e.g. a paused WhatsApp check-in video) to show where a movement should go. The
/// strokes sit above other windows, so ScreenCaptureKit records them, and they stay until the
/// coach clears them. When drawing is off the overlay is click-through, so the coach can still
/// use whatever's underneath.
@MainActor
final class AnnotationOverlay {
    private var window: AnnotationWindow?
    private let canvas = AnnotationCanvasView()

    /// Called when the coach presses Esc while drawing — a universal "stop drawing" that works
    /// even when the on-screen button is hidden beneath the overlay. The app syncs its state.
    var onExitDrawing: (() -> Void)?

    /// True while there are strokes on screen (so the UI can enable/disable "clear").
    var hasStrokes: Bool { canvas.hasStrokes }

    /// Turn draw mode on/off. Strokes persist across toggles until `clear()`.
    func setDrawing(_ on: Bool) {
        ensureWindow()
        canvas.drawingEnabled = on
        window?.ignoresMouseEvents = !on
        if on {
            window?.orderFrontRegardless()
            window?.makeKey()
            window?.makeFirstResponder(canvas)
        }
    }

    func clear() { canvas.clear() }

    /// Remove the overlay entirely (e.g. when recording ends).
    func teardown() {
        canvas.clear()
        canvas.drawingEnabled = false
        window?.orderOut(nil)
        window = nil
    }

    private func ensureWindow() {
        guard window == nil else { return }
        // Cover the screen the pointer is on (where the coach is working).
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }

        let w = AnnotationWindow(contentRect: screen.frame, styleMask: .borderless,
                                 backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        // Above normal app windows (so it draws over WhatsApp etc. and is captured by SCK) but
        // BELOW the float cam (.floating) so the float cam's Draw/Clear/Stop buttons stay
        // clickable while drawing — otherwise the coach can't turn drawing off or stop.
        w.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.ignoresMouseEvents = true
        canvas.frame = w.contentLayoutRect
        canvas.autoresizingMask = [.width, .height]
        canvas.onEscape = { [weak self] in self?.setDrawing(false); self?.onExitDrawing?() }
        w.contentView?.addSubview(canvas)
        w.orderFrontRegardless()
        window = w
    }
}

/// Borderless windows can't become key by default; drawing needs key so mouse-drags track.
final class AnnotationWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Freehand pen. Renders committed strokes plus the one in progress.
final class AnnotationCanvasView: NSView {
    var drawingEnabled = false
    var onEscape: (() -> Void)?
    private var strokes: [[NSPoint]] = []
    private var current:  [NSPoint]  = []

    private let strokeColor = NSColor.systemRed
    private let strokeWidth: CGFloat = 4

    var hasStrokes: Bool { !strokes.isEmpty || current.count > 1 }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    // Accept the very first click (window not key yet) so a stroke isn't swallowed.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { if drawingEnabled { addCursorRect(bounds, cursor: .crosshair) } }
    // Let clicks pass straight through when not drawing.
    override func hitTest(_ point: NSPoint) -> NSView? { drawingEnabled ? super.hitTest(point) : nil }

    override func mouseDown(with e: NSEvent) {
        guard drawingEnabled else { return }
        current = [convert(e.locationInWindow, from: nil)]
        needsDisplay = true
    }
    override func mouseDragged(with e: NSEvent) {
        guard drawingEnabled else { return }
        current.append(convert(e.locationInWindow, from: nil))
        needsDisplay = true
    }
    override func mouseUp(with e: NSEvent) {
        guard drawingEnabled else { return }
        if current.count > 1 { strokes.append(current) }
        current = []
        needsDisplay = true
    }
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { onEscape?() }   // Esc → stop drawing
        else { super.keyDown(with: e) }
    }

    func clear() { strokes = []; current = []; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        strokeColor.setStroke()
        for s in strokes where s.count > 1 { path(for: s).stroke() }
        if current.count > 1 { path(for: current).stroke() }
    }

    private func path(for pts: [NSPoint]) -> NSBezierPath {
        let p = NSBezierPath()
        p.lineWidth = strokeWidth
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        p.move(to: pts[0])
        for pt in pts.dropFirst() { p.line(to: pt) }
        return p
    }
}
