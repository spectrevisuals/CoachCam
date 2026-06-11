import AppKit
import SwiftUI

final class FloatingCameraPanel: NSPanel {

    init(camera: CameraManager,
         appState: AppState,
         onStart: @escaping () -> Void,
         onPauseResume: @escaping () -> Void,
         onStop: @escaping () -> Void,
         onCancelCountdown: @escaping () -> Void) {

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
        hasShadow = true
        ignoresMouseEvents = false

        if let screen = NSScreen.main {
            setFrameOrigin(NSPoint(
                x: screen.visibleFrame.maxX - 180,
                y: screen.visibleFrame.minY + 20
            ))
        }

        contentView = NSHostingView(rootView: FloatingCameraView(
            camera: camera,
            appState: appState,
            onStart: onStart,
            onPauseResume: onPauseResume,
            onStop: onStop,
            onCancelCountdown: onCancelCountdown,
            onClose: { [weak self] in self?.close() }
        ))
    }
}

private struct FloatingCameraView: View {
    @ObservedObject var camera: CameraManager
    @ObservedObject var appState: AppState
    let onStart: () -> Void
    let onPauseResume: () -> Void
    let onStop: () -> Void
    let onCancelCountdown: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            cameraCircle
            controlStrip
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 4)
        }
        .frame(width: 160, height: 218)
        .animation(.easeOut(duration: 0.2), value: appState.countdownValue)
        .animation(.easeOut(duration: 0.2), value: appState.isRecording)
    }

    // MARK: Camera circle

    private var cameraCircle: some View {
        ZStack(alignment: .topTrailing) {
            // Feed
            Group {
                if let frame = camera.currentFrame {
                    Image(nsImage: NSImage(ciImage: frame))
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
            .frame(width: 160, height: 160)
            .clipShape(Circle())
            .shadow(radius: 8)

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
                .frame(width: 160, height: 160)
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
                .frame(width: 160, height: 160)
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
        .frame(width: 160, height: 160)
    }

    // MARK: Controls

    @ViewBuilder
    private var controlStrip: some View {
        if appState.countdownValue != nil {
            Button("Cancel", action: onCancelCountdown)
                .frame(maxWidth: .infinity, minHeight: 34)
                .buttonStyle(FloatButtonStyle(color: Color(white: 0.25)))

        } else if appState.isRecording {
            HStack(spacing: 8) {
                Button(action: onPauseResume) {
                    Image(systemName: appState.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(FloatButtonStyle(color: appState.isPaused ? .green : .orange))

                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(FloatButtonStyle(color: .red))
            }

        } else {
            Button(action: onStart) {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text("Record").font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(FloatButtonStyle(color: Color(white: 0.15)))
        }
    }

    private var timerString: String {
        let d = Int(appState.recordingDuration)
        return String(format: "%02d:%02d", d / 60, d % 60)
    }
}

private struct FloatButtonStyle: ButtonStyle {
    var color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.white)
            .background(
                RoundedRectangle(cornerRadius: 8)
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
