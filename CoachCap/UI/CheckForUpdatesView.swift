import SwiftUI
import Sparkle

/// A "Check for Updates…" menu command wired to Sparkle. The button stays disabled
/// while the updater is mid-check so the user can't kick off overlapping checks.
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        // Sparkle fires this KVO publisher from its own background queues; hop to main
        // before touching @Published, or SwiftUI's update graph gets entered off-main
        // (same deadlock class as DateCompareLoader — see that file's @MainActor note).
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!viewModel.canCheckForUpdates)
    }
}
