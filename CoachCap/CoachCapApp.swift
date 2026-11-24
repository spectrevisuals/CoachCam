import SwiftUI
import Sparkle
import CoreText

@main
struct CoachCapApp: App {
    @StateObject private var appState = AppState()

    // Sparkle: starts the updater, which performs scheduled background checks
    // (gated by SUEnableAutomaticChecks in Info.plist) and drives in-place updates
    // that preserve the app's identity — so camera/screen permissions carry over.
    //
    // Deliberately has NO default value: a stored property's default runs before the body of
    // `init`, which would start Sparkle ahead of crash reporting. It is created in `init`,
    // straight after `Telemetry.start()`, with the same arguments as before.
    private let updaterController: SPUStandardUpdaterController

    init() {
        // Crash and error reporting comes first, so everything after it — Sparkle included — is
        // covered. Does nothing without a DSN in Info.plist or when the coach has opted out.
        // It also runs the previous-session check and schedules the launch scan for recordings
        // that never finalised (`RecordingsHealthScan`, off the main thread), so there is no
        // separate scan call here. File names (which hold client names) are never sent.
        Telemetry.start()

        // Clean-exit marker: a normal quit (Cmd-Q, Dock, Sparkle's relaunch, log out) writes
        // "clean"; a crash, force quit or power loss cannot, and the next launch reports it.
        // `queue: nil` runs the block synchronously on the posting thread, so the small write
        // has finished before the app goes on to exit. Inert when telemetry is off.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in
            SessionMarker.shared.markCleanExit()
        }

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
        )

        // Register the bundled Quicksand font so SwiftUI's Font.custom("Quicksand") works.
        if let url = Bundle.main.url(forResource: "Quicksand", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        // Wire the transcriber's error sink to the shared error log (it can't import
        // RecordingSession directly — the unit-test target compiles it standalone).
        VideoTranscriber.log = { RecordingSession.appendErrorLog($0) }
        Task { @MainActor in Analytics.setup() }

        SentryLaunchTriggers.scheduleIfRequested()
    }

    // NOTE: `body` is re-evaluated about once a second while recording (whenever AppState
    // publishes). Nothing with side effects may sit in it — only inside button actions.
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .background(Brand.bg.ignoresSafeArea())
                .brandTheme()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
            #if DEBUG
            // Debug builds only — not compiled into Release. No keyboard shortcuts on purpose
            // (the photo tool's key monitor swallows plain keys). The notarised build is
            // verified with the hidden launch arguments instead: see `SentryLaunchTriggers`.
            // When reporting is off the two items are greyed out and a line above them says
            // why, so a click that sends nothing cannot be mistaken for one that did.
            // (`isReporting` is fixed once `Telemetry.start()` has run; reading it has no
            // side effects.)
            CommandMenu("Debug") {
                if !Telemetry.isReporting {
                    Text("Sentry is off in this build: no DSN, opted out, or a test run")
                }
                Button("Send Sentry test error") { Telemetry.sendTestError() }
                    .disabled(!Telemetry.isReporting)
                Button("Send Sentry test crash") { Telemetry.sendTestCrash() }
                    .disabled(!Telemetry.isReporting)
            }
            #endif
        }
    }
}

/// Hidden launch arguments that prove crash and error reporting works in a signed, notarised
/// Release build (which has no Debug menu). Quit CoachCam first, then in Terminal:
///
///     open -a /Applications/CoachCam.app --args -sentryTestError YES
///     open -a /Applications/CoachCam.app --args -sentryTestCrash YES
///
/// (`open`, not the binary path, so the app keeps its own camera / screen permissions.)
/// `-sentryTestError` sends one harmless test event. `-sentryTestCrash` crashes the app on
/// purpose about two seconds after launch; the crash report is sent the NEXT time the app is
/// opened. Both do nothing when reporting is off (no DSN, opted out, or an autotest run).
///
/// That next opening must be a NORMAL one. A launch that counts as a test run — through
/// `autotest.sh`, or with a `simulate…StallAfterSeconds` default still set — sends nothing and
/// throws the waiting crash report away. So after a real or a test crash, open CoachCam
/// normally once before running the harness or arming a stall key.
///
/// The values are read from the ARGUMENT DOMAIN ONLY — what was typed on this launch's command
/// line. A value saved with `defaults write` is ignored, so nothing persistent can ever make
/// the app crash on every launch.
private enum SentryLaunchTriggers {

    static func scheduleIfRequested() {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        let wantsError = isYes(arguments["sentryTestError"])
        let wantsCrash = isYes(arguments["sentryTestCrash"])
        guard wantsError || wantsCrash else { return }

        // A couple of seconds after launch, so the SDK has settled and the window is up.
        if wantsError {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                Telemetry.sendTestError()
            }
        }
        if wantsCrash {
            // When both were asked for, give the test error a few seconds to be handed over
            // before the app goes down.
            DispatchQueue.main.asyncAfter(deadline: .now() + (wantsError ? 6 : 2)) {
                Telemetry.sendTestCrash()
            }
        }
    }

    /// Command-line values arrive as strings ("YES", "true", "1"); accept a real boolean too.
    private static func isYes(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String { return (text as NSString).boolValue }
        return false
    }
}
