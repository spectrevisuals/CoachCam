import Foundation
import AmplitudeSwift

/// Thin wrapper around Amplitude so call sites stay one-liners and the vendor could be
/// swapped without touching them.
///
/// PRIVACY RULES (health-adjacent client content): only feature-usage events with coarse
/// properties — NEVER client names, file names/paths, transcript text, or search queries.
/// Fully disabled (no SDK init, no network) until an API key is pasted below, and always
/// disabled during autotest runs so CI doesn't pollute the numbers.
enum Analytics {
    /// Paste the Amplitude project API key here (Amplitude → Settings → Projects → API Key).
    /// Empty string = analytics completely off.
    private static let apiKey = "a34ad516dc4a06861fa654038407d378"

    nonisolated(unsafe) private static var amplitude: Amplitude?

    @MainActor
    static func setup() {
        guard !apiKey.isEmpty,
              UserDefaults.standard.string(forKey: "autotest") == nil else { return }
        amplitude = Amplitude(configuration: Configuration(
            apiKey: apiKey,
            // Jake's project lives in Amplitude's EU data centre (verified 2026-09-28: US
            // endpoint rejects this key, EU ingests). Without this, events silently vanish.
            serverZone: .EU
        ))
        track("app_opened")
    }

    static func track(_ event: String, _ props: [String: Any] = [:]) {
        amplitude?.track(eventType: event, eventProperties: props)
    }
}
