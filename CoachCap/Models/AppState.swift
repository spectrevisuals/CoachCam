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

    // Client name for auto-naming the output file
    @Published var clientName: String = ""

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
