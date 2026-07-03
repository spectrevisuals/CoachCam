import Foundation
import SwiftUI
import AVFoundation

enum AppTab { case recorder, photoTool }

@MainActor
final class AppState: ObservableObject {
    // Navigation
    @Published var activeTab: AppTab = .recorder

    // Recording state
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var recordingDuration: TimeInterval = 0

    // PiP position — normalised rect (0-1). Burned into every frame.
    @Published var pipRect = CGRect(x: 0.72, y: 0.04, width: 0.24, height: 0.24)

    // Source selection
    @Published var selectedCameraID: String? = nil
    @Published var selectedMicID: String? = nil
    @Published var selectedDisplayID: CGDirectDisplayID? = nil   // nil = primary
    @Published var webcamOnlyMode = false
    // Draw-on-screen (annotation/telestrator) mode: when on, the coach can draw lines over
    // anything on screen; lines stay until cleared. Toggled from the recorder or float cam.
    @Published var isAnnotating = false

    // Loom-style "custom area": when set, only the screen content inside this rect is
    // recorded. Rect is in the target display's coordinate space (points, top-left origin,
    // matching SCStreamConfiguration.sourceRect). Pixel size is precomputed for the output.
    @Published var customArea: CGRect? = nil
    @Published var customAreaDisplayID: CGDirectDisplayID? = nil
    @Published var customAreaPixelSize: CGSize? = nil

    // Auto-hide: minimise the main window while recording. Lives here (not @AppStorage in
    // the view) so the float cam's captured closures always read the live value. Persisted.
    //
    // Two independent settings because the two workflows want opposite defaults:
    //  • Recorder screen: defaults ON — you're recording your screen (Google Sheets etc.),
    //    so getting the CoachCam window out of the way is what you want.
    //  • Before/after screen: defaults OFF — you're recording the CoachCam window itself
    //    (explaining the photos), so minimising would hide the very thing being shown.
    // hideMainWindowForRecording() picks the right one based on the active screen.
    @Published var hideWindowWhileRecording: Bool = UserDefaults.standard.object(forKey: "hideWindowWhileRecording") as? Bool ?? true {
        didSet { UserDefaults.standard.set(hideWindowWhileRecording, forKey: "hideWindowWhileRecording") }
    }
    @Published var hideWindowWhileRecordingBeforeAfter: Bool = UserDefaults.standard.object(forKey: "hideWindowWhileRecordingBeforeAfter") as? Bool ?? false {
        didSet { UserDefaults.standard.set(hideWindowWhileRecordingBeforeAfter, forKey: "hideWindowWhileRecordingBeforeAfter") }
    }

    // Float cam circle diameter (points). Cycled S/M/L from the float cam; remembered.
    @Published var floatCamDiameter: CGFloat = {
        let v = UserDefaults.standard.double(forKey: "floatCamDiameter")
        return v > 0 ? CGFloat(v) : 160
    }() {
        didSet { UserDefaults.standard.set(Double(floatCamDiameter), forKey: "floatCamDiameter") }
    }

    // Countdown + sound preferences (persisted, on by default). `countdownEnabled` off starts
    // recording immediately with no 3-2-1; `soundEffectsEnabled` mutes the start/stop chimes.
    @Published var countdownEnabled: Bool = UserDefaults.standard.object(forKey: "countdownEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(countdownEnabled, forKey: "countdownEnabled") }
    }
    @Published var soundEffectsEnabled: Bool = UserDefaults.standard.object(forKey: "soundEffectsEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(soundEffectsEnabled, forKey: "soundEffectsEnabled") }
    }

    // Client name for auto-naming the output file
    @Published var clientName: String = ""

    // The WhatsApp contact the coach last selected in the photo tool — used to open the
    // correct chat when sending a check-in video.
    @Published var whatsAppClientName: String? = nil

    // Last saved file (for "Show in Finder" button)
    @Published var lastSavedURL: URL? = nil

    // Error shown in a sheet/alert
    @Published var errorMessage: String? = nil

    // Countdown before recording starts (3 → 2 → 1 → nil)
    @Published var countdownValue: Int? = nil

    // Saving/compression in progress
    @Published var isSaving = false

    // Countdown task — held here so closures in FloatingCameraPanel can cancel it
    var countdownTask: Task<Void, Never>? = nil

    // Timer
    private var timer: AnyCancellable?

    func startTimer() {
        timer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.recordingDuration += 1 }
    }

    func stopTimer() {
        timer = nil
        recordingDuration = 0
    }

    func pauseTimer() { timer = nil }

    func resumeTimer() { startTimer() }
}

// Combine import for AnyCancellable
import Combine
