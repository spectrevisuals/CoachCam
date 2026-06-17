import AppKit

/// Loom-style "custom area" picker. Drops a full-screen overlay; the coach drags a
/// rectangle and only the screen content inside it gets recorded. Returns the rect in the
/// target display's coordinate space (points, **top-left origin** — matching
/// `SCStreamConfiguration.sourceRect`) plus that display's ID. A `nil` rect = cancelled.
@MainActor
final class AreaSelectorController {
    private var window: AreaSelectorWindow?
    private let completion: (CGRect?, CGDirectDisplayID?) -> Void

    init(completion: @escaping (CGRect?, CGDirectDisplayID?) -> Void) {
        self.completion = completion
    }

    func present(on screen: NSScreen) {
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value ?? CGMainDisplayID()

        let win = AreaSelectorWindow(screen: screen) { [weak self] rect in
            guard let self else { return }
            self.window?.orderOut(nil)
            self.window = nil
            self.completion(rect, rect == nil ? nil : displayID)
        }
        window = win
        // Show the overlay WITHOUT activating CoachCam. Activation would pull the main window
        // in front of the very content the coach is boxing; a non-activating panel stays
        // interactive (drag to select) without stealing focus or raising our windows.
        win.orderFrontRegardless()
    }
}

final class AreaSelectorWindow: NSPanel {
    private let onDone: (CGRect?) -> Void

    init(screen: NSScreen, onDone: @escaping (CGRect?) -> Void) {
        self.onDone = onDone
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        setFrame(screen.frame, display: true)
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = AreaSelectorView(frame: NSRect(origin: .zero, size: screen.frame.size), onDone: onDone)
    }

    override var canBecomeKey: Bool { true }

    // Esc still cancels if CoachCam happens to be the active app; the primary cancel path is
    // a plain click (handled in AreaSelectorView), since a non-activating panel won't reliably
    // receive key events when another app is frontmost.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onDone(nil) }   // Esc cancels
    }
}

/// A persistent, click-through orange outline of the active custom area, so the coach can
/// always see what's being recorded. The stroke is drawn just *outside* the captured rect,
/// so it stays out of the recording itself.
final class AreaIndicatorWindow: NSWindow {
    init(screen: NSScreen, rect: CGRect) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        setFrame(screen.frame, display: true)
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true            // click-through — never blocks the coach
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let v = AreaIndicatorView(frame: NSRect(origin: .zero, size: screen.frame.size))
        v.rect = rect
        contentView = v
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class AreaIndicatorView: NSView {
    var rect: CGRect = .zero { didSet { needsDisplay = true } }
    private let accent = NSColor(calibratedRed: 253/255, green: 86/255, blue: 1/255, alpha: 1)

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard rect.width > 1, rect.height > 1 else { return }
        // Inner edge of the stroke sits ~1pt outside the captured rect, so it's never
        // part of the recording.
        accent.setStroke()
        let path = NSBezierPath(rect: rect.insetBy(dx: -2.5, dy: -2.5))
        path.lineWidth = 3
        path.stroke()

        // Small "recording area" tag above the box (also outside the captured region).
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let str = NSAttributedString(string: "recording area", attributes: attrs)
        let sz = str.size(), pad: CGFloat = 6
        let box = NSRect(x: rect.minX - 2.5, y: max(2, rect.minY - sz.height - pad - 6),
                         width: sz.width + pad * 2, height: sz.height + pad)
        accent.setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        str.draw(at: NSPoint(x: box.minX + pad, y: box.minY + pad / 2))
    }
}

private final class AreaSelectorView: NSView {
    private let onDone: (CGRect?) -> Void
    private var startPoint: NSPoint?
    private var selection: NSRect = .zero
    private let accent = NSColor(calibratedRed: 253/255, green: 86/255, blue: 1/255, alpha: 1)

    init(frame: NSRect, onDone: @escaping (CGRect?) -> Void) {
        self.onDone = onDone
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override var isFlipped: Bool { true }   // top-left origin so coords map to sourceRect

    // The overlay panel is non-activating, so without this the first click would only focus
    // the window and the initial drag would be ignored — making the coach drag twice.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with e: NSEvent) {
        startPoint = convert(e.locationInWindow, from: nil)
        selection = .zero
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        guard let s = startPoint else { return }
        let p = convert(e.locationInWindow, from: nil)
        selection = NSRect(x: min(s.x, p.x), y: min(s.y, p.y),
                           width: abs(p.x - s.x), height: abs(p.y - s.y))
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        if selection.width >= 40, selection.height >= 40 {
            onDone(selection)                       // usable box → confirm
        } else if selection.width < 1, selection.height < 1 {
            onDone(nil)                             // plain click (no drag) → cancel
        } else {
            selection = .zero                       // fumbled tiny drag → reset, try again
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSColor.black.withAlphaComponent(0.45)
        dim.setFill()

        if selection.width < 1 || selection.height < 1 {
            bounds.fill()
        } else {
            // Dim everything except the selection (four surrounding strips).
            let b = bounds, s = selection
            NSRect(x: 0, y: 0, width: b.width, height: s.minY).fill()                                  // top
            NSRect(x: 0, y: s.maxY, width: b.width, height: b.height - s.maxY).fill()                  // bottom
            NSRect(x: 0, y: s.minY, width: s.minX, height: s.height).fill()                            // left
            NSRect(x: s.maxX, y: s.minY, width: b.width - s.maxX, height: s.height).fill()             // right

            // Orange border + size badge.
            accent.setStroke()
            let path = NSBezierPath(rect: s.insetBy(dx: -1, dy: -1))
            path.lineWidth = 2
            path.stroke()

            let scale = window?.backingScaleFactor ?? 2
            let w = Int((s.width * scale).rounded()), h = Int((s.height * scale).rounded())
            drawBadge("\(w) × \(h)", at: NSPoint(x: s.minX, y: max(4, s.minY - 26)))
        }

        drawBadge("drag to select an area  ·  click to cancel",
                  at: NSPoint(x: bounds.midX - 150, y: 18), wide: true)
    }

    private func drawBadge(_ text: String, at origin: NSPoint, wide: Bool = false) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: wide ? 13 : 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        let pad: CGFloat = 7
        let box = NSRect(x: origin.x, y: origin.y, width: size.width + pad * 2, height: size.height + pad)
        let bg = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
        NSColor.black.withAlphaComponent(0.72).setFill()
        bg.fill()
        str.draw(at: NSPoint(x: box.minX + pad, y: box.minY + pad / 2))
    }
}
