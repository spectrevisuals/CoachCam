import AppKit
import SwiftUI
import Combine

final class FloatingCameraPanel: NSPanel {

    private var sizeCancellable: AnyCancellable?
    private let controlsHeight: CGFloat = 58

    init(camera: CameraManager,
         appState: AppState,
         onStart: @escaping () -> Void,
         onPauseResume: @escaping () -> Void,
         onStop: @escaping () -> Void,
         onCancelCountdown: @escaping () -> Void,
         onSkipCountdown: @escaping () -> Void,
         onCustomArea: @escaping () -> Void,
         onAnnotateToggle: @escaping () -> Void,
         onToggleStraightLine: @escaping () -> Void,
         onClearAnnotations: @escaping () -> Void) {

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 218),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        // The backing is now a rounded-rect brand card (see host.layer below), so the
        // window shadow traces a clean rounded shape — no more jagged halo.
        hasShadow = true
        ignoresMouseEvents = false

        if let screen = NSScreen.main {
            setFrameOrigin(NSPoint(
                x: screen.visibleFrame.maxX - 180,
                y: screen.visibleFrame.minY + 20
            ))
        }

        let host = NSHostingView(rootView: FloatingCameraView(
            camera: camera,
            appState: appState,
            onStart: onStart,
            onPauseResume: onPauseResume,
            onStop: onStop,
            onCancelCountdown: onCancelCountdown,
            onSkipCountdown: onSkipCountdown,
            onCustomArea: onCustomArea,
            onAnnotateToggle: onAnnotateToggle,
            onToggleStraightLine: onToggleStraightLine,
            onClearAnnotations: onClearAnnotations,
            onClose: { [weak self] in self?.close() }
        ))
        host.autoresizingMask = [.width, .height]
        // The hosting view backing is unavoidably a filled rectangle; rather than fight it,
        // make it an intentional dark, rounded brand card so the whole float cam reads as a
        // soft branded bubble instead of a harsh light-grey rectangle.
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor(Color(hex: 0x46454B, alpha: 0.70)).cgColor   // soft brand grey, slightly translucent
        host.layer?.cornerRadius = 22
        host.layer?.cornerCurve = .continuous
        contentView = host

        // Resize the panel (anchored to its bottom-right corner) whenever the coach
        // cycles the float cam size.
        sizeCancellable = appState.$floatCamDiameter.sink { [weak self] d in self?.applySize(d) }
    }

    private func applySize(_ d: CGFloat) {
        let newSize = NSSize(width: d, height: d + controlsHeight)
        guard abs(frame.width - newSize.width) > 0.5 || abs(frame.height - newSize.height) > 0.5 else { return }
        var f = frame
        // Grow from the bottom-right corner (kept pinned), so a bottom-right-docked cam
        // expands up-and-left and stays put on screen. The grip lives at the top-left.
        let right = f.maxX, bottom = f.minY
        f.size = newSize
        f.origin = NSPoint(x: right - newSize.width, y: bottom)
        // Keep the whole panel on screen so the controls never slide off the edge.
        if let vf = (screen ?? NSScreen.main)?.visibleFrame {
            f.origin.x = min(max(f.origin.x, vf.minX), max(vf.minX, vf.maxX - newSize.width))
            f.origin.y = min(max(f.origin.y, vf.minY), max(vf.minY, vf.maxY - newSize.height))
        }
        setFrame(f, display: true, animate: false)
    }
}

private struct FloatingCameraView: View {
    @ObservedObject var camera: CameraManager
    @ObservedObject var appState: AppState
    let onStart: () -> Void
    let onPauseResume: () -> Void
    let onStop: () -> Void
    let onCancelCountdown: () -> Void
    let onSkipCountdown: () -> Void
    let onCustomArea: () -> Void
    let onAnnotateToggle: () -> Void
    let onToggleStraightLine: () -> Void
    let onClearAnnotations: () -> Void
    let onClose: () -> Void

    private var d: CGFloat { appState.floatCamDiameter }
    private let controlsHeight: CGFloat = 58
    private let minDiameter: CGFloat = 90
    private let maxDiameter: CGFloat = 380

    // Orange branded ring around the circle — scales gently with the cam size.
    private var ringWidth: CGFloat { max(3, d * 0.025) }
    // Small "CC" logo watermark size.
    private var badgeSize: CGFloat { max(22, min(40, d * 0.16)) }

    var body: some View {
        VStack(spacing: 0) {
            cameraCircle
            controlStrip
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 4)
                // The control bar casts its own soft shadow that hugs the rounded buttons,
                // rather than a boxy full-frame shadow behind the whole panel.
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        }
        .frame(width: d, height: d + controlsHeight)
        .overlay(alignment: .topLeading) { resizeGrip }
        .animation(.easeOut(duration: 0.2), value: appState.countdownValue)
        .animation(.easeOut(duration: 0.2), value: appState.isRecording)
    }

    // MARK: Camera circle

    private var cameraCircle: some View {
        ZStack(alignment: .topTrailing) {
            // Feed
            Group {
                if let frame = camera.previewImage {
                    Image(decorative: frame, scale: 1, orientation: .up)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.black
                        .overlay(
                            Image(systemName: "video.slash.fill")
                                .font(.system(size: 28))
                                .foregroundColor(.white.opacity(0.4))
                        )
                }
            }
            .frame(width: d, height: d)
            .clipShape(Circle())

            // Countdown overlay on the circle
            if let count = appState.countdownValue {
                ZStack {
                    Circle().fill(Color.black.opacity(0.55))
                    Text("\(count)")
                        .font(.system(size: 68, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .id(count)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.5).combined(with: .opacity),
                            removal:   .scale(scale: 1.5).combined(with: .opacity)
                        ))
                }
                .frame(width: d, height: d)
                .clipShape(Circle())
            }

            // Elapsed time badge when recording
            if appState.isRecording && appState.countdownValue == nil {
                VStack {
                    Spacer()
                    HStack(spacing: 4) {
                        Circle()
                            .fill(appState.isPaused ? Color.orange : Color.red)
                            .frame(width: 6, height: 6)
                        Text(timerString)
                            .font(.system(.caption2, design: .monospaced).bold())
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.6))
                    .clipShape(Capsule())
                    .padding(.bottom, 8)
                }
                .frame(width: d, height: d)
            }

            // Close button (top-right, always visible)
            if !appState.isRecording && appState.countdownValue == nil {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.5), radius: 2)
                }
                .buttonStyle(.plain)
                .padding(4)
            }

        }
        .frame(width: d, height: d)
        // Crisp orange branded ring instead of the old jagged shadow halo.
        .overlay(
            Circle()
                .strokeBorder(
                    LinearGradient(colors: [Brand.accent2, Brand.accent],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: ringWidth)
        )
        // Small "CC" logo badge nestled on the lower-right rim. The corner of the square
        // bounding box sits outside the circular feed, so the mark never covers the camera.
        .overlay(alignment: .bottomTrailing) {
            ccBadge.padding([.bottom, .trailing], max(3, d * 0.02))
        }
        .shadow(color: .black.opacity(0.45), radius: 10, y: 3)
    }

    // The "CC" app-mark, pinned to the lower-right rim as a subtle brand badge.
    private var ccBadge: some View {
        Image("CCBadge")
            .resizable()
            .interpolation(.high)
            .frame(width: badgeSize, height: badgeSize)
            .clipShape(RoundedRectangle(cornerRadius: badgeSize * 0.28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: badgeSize * 0.28, style: .continuous)
                .stroke(Color.white.opacity(0.9), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
    }

    // MARK: Controls

    @ViewBuilder
    private var controlStrip: some View {
        if appState.countdownValue != nil {
            HStack(spacing: 8) {
                Button(action: onSkipCountdown) {
                    Text("start").font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(FloatButtonStyle(color: Brand.accent))

                Button(action: onCancelCountdown) {
                    Text("cancel").font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(FloatButtonStyle(color: Color(white: 0.25)))
            }

        } else if appState.isRecording {
            HStack(spacing: 6) {
                Button(action: onPauseResume) {
                    Image(systemName: appState.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(FloatButtonStyle(color: appState.isPaused ? Color(hex: 0x28C840) : Brand.accent))

                // Draw-on-screen toggle — highlighted while drawing.
                Button(action: onAnnotateToggle) {
                    Image(systemName: "pencil.tip")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(FloatButtonStyle(color: appState.isAnnotating ? Brand.accent2 : Color(white: 0.25)))
                .help("Draw on screen — tap, then drag to draw lines. Tap again to stop drawing.")

                // Pen vs straight-line tool — only while drawing, so the row stays uncluttered.
                if appState.isAnnotating {
                    Button(action: onToggleStraightLine) {
                        Image(systemName: appState.annotationStraightLine ? "line.diagonal" : "scribble.variable")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 34)
                    }
                    .buttonStyle(FloatButtonStyle(color: appState.annotationStraightLine ? Brand.accent : Color(white: 0.25)))
                    .help("Straight line or freehand pen (Shift also draws a straight line)")
                }

                // Clear all drawn lines.
                Button(action: onClearAnnotations) {
                    Image(systemName: "eraser")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(FloatButtonStyle(color: Color(white: 0.25)))
                .help("Clear the drawn lines")

                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(FloatButtonStyle(color: Brand.danger))
            }

        } else {
            HStack(spacing: 6) {
                Button(action: onStart) {
                    HStack(spacing: 6) {
                        Circle().fill(.red).frame(width: 8, height: 8)
                        Text("Record").font(.system(size: 13, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(FloatButtonStyle(color: Color(white: 0.15)))

                Button(action: onCustomArea) {
                    Image(systemName: appState.customArea == nil ? "rectangle.dashed" : "rectangle.dashed.badge.record")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(appState.customArea == nil ? .white : Brand.accent)
                        .frame(width: 38, height: 34)
                }
                .buttonStyle(FloatButtonStyle(color: Color(white: 0.25)))
                .help("Record only a custom area — tap to draw a box, tap again to clear")
            }
        }
    }

    // Drag the bottom-right grip to resize the float cam to any size. The grip is an
    // AppKit view that declares mouseDownCanMoveWindow = false, so dragging it resizes
    // instead of moving the window (the rest of the bubble still drags to reposition).
    private var resizeGrip: some View {
        ZStack {
            Image(systemName: "arrow.up.left")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white.opacity(0.8))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.black.opacity(0.5)))
            ResizeGrip(diameter: { appState.floatCamDiameter },
                       minD: minDiameter, maxD: maxDiameter,
                       onChange: { appState.floatCamDiameter = $0 })
                .frame(width: 30, height: 30)
        }
        .padding(5)
        .help("Drag to resize the float cam")
    }

    private var timerString: String {
        let d = Int(appState.recordingDuration)
        return String(format: "%02d:%02d", d / 60, d % 60)
    }
}

/// AppKit-backed resize handle. Because it returns `mouseDownCanMoveWindow = false`,
/// dragging it resizes the float cam instead of the window's background-drag moving it.
private struct ResizeGrip: NSViewRepresentable {
    let diameter: () -> CGFloat
    let minD: CGFloat
    let maxD: CGFloat
    let onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> ResizeGripView {
        let v = ResizeGripView()
        v.minD = minD; v.maxD = maxD
        v.diameter = diameter; v.onChange = onChange
        return v
    }
    func updateNSView(_ v: ResizeGripView, context: Context) {
        v.diameter = diameter; v.onChange = onChange
    }
}

final class ResizeGripView: NSView {
    var diameter: () -> CGFloat = { 160 }
    var onChange: (CGFloat) -> Void = { _ in }
    var minD: CGFloat = 90
    var maxD: CGFloat = 380

    private var startD: CGFloat = 0
    private var startMouse: NSPoint = .zero

    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        startD = diameter()
        startMouse = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        let cur = NSEvent.mouseLocation
        let dxLeft = startMouse.x - cur.x      // drag left  = larger
        let dyUp   = cur.y - startMouse.y      // drag up    = larger
        let delta = (dxLeft + dyUp) / 2
        onChange(min(maxD, max(minD, startD + delta)))
    }
}

private struct FloatButtonStyle: ButtonStyle {
    var color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.white)
            .background(
                RoundedRectangle(cornerRadius: Brand.rControl, style: .continuous)
                    .fill(color.opacity(configuration.isPressed ? 0.5 : 0.9))
            )
    }
}

private extension NSImage {
    convenience init(ciImage: CIImage) {
        let rep = NSCIImageRep(ciImage: ciImage)
        self.init(size: rep.size)
        addRepresentation(rep)
    }
}
