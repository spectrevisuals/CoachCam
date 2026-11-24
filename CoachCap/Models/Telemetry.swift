import AppKit        // NSRunningApplication (is another copy of the app already open?)
import Foundation
import SentrySwift   // The ONLY file in the project that imports the Sentry module.

/// Crash and error reporting (Sentry), behind one small, typed wrapper. Everything else in the
/// app calls this; nothing else touches the SDK.
///
/// PRIVACY — no user content may leave the Mac. Coaches record client check-ins: recording file
/// names contain client names and every path contains the macOS account name. The API below is
/// typed so that this is hard to get wrong:
///  * messages, event names, data keys and tokens are `StaticString` — compile-time constants;
///  * values are a closed enum (`Value`): numbers, booleans, constant tokens, and an error's
///    domain and code. There is deliberately NO case that takes an arbitrary run-time `String`;
///  * an `Error` handed to `captureFailure` is reduced to domain + code (and the underlying
///    error's domain + code) before anything else happens. Its description and `userInfo`
///    (which hold `NSFilePath` / `NSURL`) never reach the SDK.
/// Never pass a URL, path, file or folder name, client name, device or display name, host name,
/// licence key, transcript text, search query or `error.localizedDescription` into a call here,
/// and do not weaken these types. `TelemetryScrubber` is a second line of defence for text the
/// SDK collects on its own (exception reasons, binary image paths).
///
/// THREADING — every function is safe to call from any thread and returns immediately. Inputs
/// are snapshotted on the caller's thread; everything that touches the SDK (locks, JSON,
/// `beforeSend`) runs later on one private serial utility queue, so a capture queue or the main
/// actor is never blocked and breadcrumbs keep their order. On capture queues, call only at
/// one-off edges (never per frame or per buffer) and never while holding a lock.
///
/// OFF BY DEFAULT — the SDK starts only when a well-formed DSN is baked into Info.plist
/// (`SentryDSN`, from the `SENTRY_DSN` build setting) and the coach has not opted out
/// (`defaults write com.coachcam.app shareDiagnostics -bool false`). Until `start()` has
/// started the SDK, every function here is a cheap no-op and the app behaves exactly as if
/// telemetry did not exist.
///
/// READING THE `usb.changed_during_recording` TAG — it only says that a USB camera or
/// microphone connect / disconnect notification had ALREADY been received in this recording
/// when the event was built. macOS can post a disconnect ten seconds or more after the device
/// stops delivering, so when the watchdog ends a recording first, the "recording interrupted"
/// event goes out with the tag false. The signature of a pulled device is then
/// `reason:watchdog_microphone` / `watchdog_camera` together with `setup.mic_transport:usb` /
/// `setup.camera_transport:usb`; and if the disconnect does arrive within 30 seconds, one
/// follow-up warning, "device disconnect confirmed after interruption", says so.
enum Telemetry {

    // MARK: - Vocabulary (closed sets)

    /// Breadcrumb categories.
    enum Category: String {
        case recording, writer, device, permission, lifecycle, scan
    }

    /// Breadcrumb severity.
    enum Level {
        case debug, info, warning, error
    }

    /// Where in a recording's life a failure happened.
    enum Stage: String {
        case start, capture, finalize, save
    }

    /// What the recorder is doing. `idle` = nothing in flight.
    enum RecordingState: String, CaseIterable {
        case idle, starting, recording, paused, finalizing
    }

    /// Kind of capture device.
    enum Media: String {
        case video, audio
    }

    /// How a capture device is attached — never its name or id.
    enum Transport: String {
        case builtIn = "built_in"
        case usb
        case bluetooth
        case continuityOrVirtual = "continuity_or_virtual"
        case other
    }

    /// The only kinds of value a telemetry call can carry.
    enum Value {
        case int(Int)
        case double(Double)
        case bool(Bool)
        /// A compile-time constant, e.g. `.token("watchdog_video")`.
        case token(StaticString)
        /// An error's domain: `.errorDomain(Telemetry.ErrorDomain(error))`. Reduced to
        /// `[A-Za-z0-9._-]`, at most 80 characters, before it is sent.
        case errorDomain(ErrorDomain)
        case errorCode(Int)
    }

    /// The domain of an error, for `Value.errorDomain`. It can only be made from an error
    /// object (`none` when there is none) — never from a string — so no run-time text can be
    /// passed through it by mistake.
    struct ErrorDomain: Sendable {
        fileprivate let raw: String

        init(_ error: Error?) {
            raw = error.map { ($0 as NSError).domain } ?? "none"
        }
    }

    /// Key/value data for a call, written as a dictionary literal with constant keys:
    /// `["duration_s": .double(12.5), "reason": .token("watchdog_video")]`.
    ///
    /// Not a real `Dictionary` on purpose: a dictionary literal with a repeated key traps at
    /// run time, and a telemetry call must never be able to crash a recording. Here a repeated
    /// key simply keeps its last value.
    struct Fields: ExpressibleByDictionaryLiteral {
        fileprivate var pairs: [(key: StaticString, value: Value)]

        init() { pairs = [] }

        init(dictionaryLiteral elements: (StaticString, Value)...) {
            pairs = elements.map { (key: $0.0, value: $0.1) }
        }

        /// Adds (or replaces) one value — for data a call site only sometimes has.
        mutating func set(_ key: StaticString, _ value: Value) {
            pairs.append((key: key, value: value))
        }

        /// This set of fields followed by another (the other's values win on a repeated key).
        func merging(_ other: Fields) -> Fields {
            var merged = self
            merged.pairs.append(contentsOf: other.pairs)
            return merged
        }
    }

    // MARK: - Start

    /// Starts crash and error reporting. Call once, as the first statement of
    /// `CoachCapApp.init`, on the main thread.
    ///
    /// Does nothing when the coach opted out, or when Info.plist holds no well-formed DSN.
    /// During an autotest run the SDK starts (so the harness exercises the instrumented
    /// pipeline with the SDK live) but nothing is sent, and the clean-exit check and the launch
    /// scan are skipped.
    static func start() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { start() }
            return
        }
        guard claimStart() else { return }

        let defaults = UserDefaults.standard

        // Opt-out: the SDK does not start at all.
        guard defaults.object(forKey: "shareDiagnostics") as? Bool ?? true else { return }

        // No DSN, or not a well-formed one: telemetry does not exist.
        let info = Bundle.main.infoDictionary
        guard let dsn = TelemetryDSN.wellFormed(info?["SentryDSN"] as? String) else { return }

        // Autotest: the harness launches with `-autotest <scenario>`; the release checklist
        // arms the stall simulations with a persistent `defaults write`.
        let autotest = defaults.string(forKey: "autotest") != nil
            || defaults.integer(forKey: "simulateVideoStallAfterSeconds") > 0
            || defaults.integer(forKey: "simulateCameraStallAfterSeconds") > 0
            || defaults.integer(forKey: "simulateMicStallAfterSeconds") > 0

        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        let userID = String(DeviceIdentity.hardwareUUID.prefix(8))
        let chip = sysctlInt32("hw.optional.arm64") == 1 ? "apple_silicon" : "intel"
        let translated = sysctlInt32("sysctl.proc_translated") == 1 ? "true" : "false"

        let options = Options()
        options.dsn = dsn
        options.releaseName = "CoachCam@\(version)+\(build)"
        if autotest {
            options.environment = "autotest"
        } else {
            #if DEBUG
            options.environment = "debug"
            #else
            options.environment = "production"
            #endif
        }
        options.debug = false
        options.sendDefaultPii = false

        // Crashes: on. Uncaught NSExceptions: off — turning that on makes AppKit crash the app
        // where today it logs and carries on (it also needs swizzling, which stays off).
        options.enableCrashHandler = true
        options.enableUncaughtNSExceptionReporting = false
        options.enableSwizzling = false
        options.enableMemoryIntrospection = false

        // App hangs: on at 5 s, paused for the whole time a recording is in flight (see
        // `setRecordingState`). MetricKit diagnostics: on, without the raw payload.
        options.enableAppHangTracking = true
        options.appHangTimeoutInterval = 5
        options.enableMetricKit = true
        options.enableMetricKitRawPayload = false

        // Release health and the SDK's few automatic breadcrumbs (app active/inactive,
        // connectivity). Nothing about the network, files, Core Data or performance.
        options.enableAutoSessionTracking = !autotest
        options.enableAutoBreadcrumbTracking = true
        options.enableNetworkBreadcrumbs = false
        options.enableCaptureFailedRequests = false
        options.enableNetworkTracking = false
        options.enableFileIOTracing = false
        options.enableDataSwizzling = false
        options.enableFileManagerSwizzling = false
        options.enableCoreDataTracing = false
        options.enableAutoPerformanceTracing = false
        // tracesSampleRate is deliberately left unset: tracing stays off.

        options.attachStacktrace = true
        options.attachAllThreads = false
        options.maxBreadcrumbs = 100
        // "Client reports" are counts of dropped events. Normally harmless; during an autotest
        // run they would be the one thing still sent, so they go too.
        options.sendClientReports = !autotest

        let identity = EventIdentity(userID: userID, chip: chip, translated: translated)
        options.beforeSend = { event in
            // An autotest run sends nothing. A crash report WRITTEN during an autotest run is
            // handed over by the next normal launch and still carries that run's environment,
            // so it is dropped here as well.
            if autotest || event.environment == "autotest" { return nil }
            return scrubbed(event, identity: identity)
        }
        options.beforeBreadcrumb = { crumb in
            scrubbed(crumb)
        }

        // Identity and the static tags are part of the very first scope, so they are also on
        // any crash report written later in this session.
        options.initialScope = { scope in
            scope.setUser(User(userId: userID))
            scope.setTag(value: chip, key: "mac.chip")
            scope.setTag(value: translated, key: "mac.translated")
            scope.setTag(value: RecordingState.idle.rawValue, key: "recording.state")
            return scope
        }

        SentrySDK.start(options: options)
        // If the SDK declined to start (it does inside an Xcode preview, for example), stay off.
        guard SentrySDK.isEnabled else { return }
        setMode(autotest ? .suppressed : .live)

        guard !autotest else { return }

        // A second copy of the app (opened from a DMG or Downloads while the installed one is
        // still open, `open -n`, a Debug run beside the installed app) must not read the first
        // copy's state file as "the previous session died", nor report its live recording as
        // truncated. This launch then leaves the clean-exit marker and the launch scan alone;
        // the file stays with the copy that was opened first.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains(where: { $0.processIdentifier != ownPID && !$0.isTerminated }) {
            return
        }

        // Clean-exit check. No file = first run with this scheme: stay silent.
        let verdict = SessionMarker.shared.beginSession(build: build)
        if case let .didNotExitCleanly(lastRecordingState, previousBuild) = verdict {
            let lastState = RecordingState(rawValue: lastRecordingState)
            let crashReport: StaticString
            switch SentrySDK.lastRunStatus {
            case .didCrash: crashReport = "yes"
            case .didNotCrash: crashReport = "no"
            default: crashReport = "unknown"
            }
            captureWarning("previous session did not exit cleanly",
                           fingerprint: ["unclean-exit", lastState?.token ?? "unknown"],
                           ["last_recording_state": .token(lastState?.token ?? "unknown"),
                            "was_recording": .bool(lastState != nil && lastState != .idle),
                            "previous_build": .int(Int(previousBuild) ?? -1),
                            // The event is filed under THIS build's release. After an update
                            // the build that died is the previous one; this makes that searchable.
                            "previous_build_differs": .bool(previousBuild != build),
                            "sdk_has_crash_report": .token(crashReport)])
        }

        // Launch scan for recordings that never finalised (off the main thread).
        RecordingsHealthScan.run()
    }

    // MARK: - Breadcrumbs

    /// Leaves a breadcrumb: a constant message plus numbers / booleans / tokens. Breadcrumbs
    /// are only sent attached to a later event or crash.
    static func breadcrumb(_ category: Category, _ message: StaticString,
                           _ data: Fields = [:], level: Level = .info) {
        guard isOn else { return }
        let timestamp = Date()
        queue.async {
            let crumb = Breadcrumb(level: level.sentryLevel, category: category.rawValue)
            crumb.message = message.description
            crumb.timestamp = timestamp
            for (key, value) in data.jsonObject {
                crumb.setData(value: value, key: key)
            }
            SentrySDK.addBreadcrumb(crumb)
        }
    }

    // MARK: - Events

    /// Sends an error-level event for a failure. `event` is a constant name for the call site
    /// ("writer failed", "start capture failed", …). Only the error's domain and code (and its
    /// underlying error's) are kept; they are read here, on the caller's thread.
    ///
    /// The standard failure context is added automatically: free disk space on the recordings
    /// volume, the recorder state, recent camera/microphone connect/disconnect events and
    /// whether a USB device changed during the recording. Pass what only the call site knows
    /// in `data`: writer status (`writerStatusFields`), duration, per-track sample counts.
    static func captureFailure(_ event: StaticString, stage: Stage, error: Error?,
                               _ data: Fields = [:]) {
        guard isOn else { return }
        let snapshot = ErrorSnapshot(error)
        let timestamp = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        queue.async {
            sendFailure(event: event, stage: stage.rawValue, error: snapshot, data: data,
                        timestamp: timestamp, uptime: uptime)
        }
    }

    /// Sends a warning-level message event. `fingerprint` (constants) decides which events are
    /// grouped into one issue. The standard failure context is added, as for `captureFailure`.
    static func captureWarning(_ event: StaticString, fingerprint: [StaticString],
                               _ data: Fields = [:]) {
        guard isOn else { return }
        let timestamp = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        queue.async {
            sendWarning(event: event, fingerprint: fingerprint.map(\.description), data: data,
                        timestamp: timestamp, uptime: uptime)
        }
    }

    /// For the ONE place that catches whatever a recording start throws (the UI). Sends `event`
    /// as a start failure — unless a more specific start failure has already been captured
    /// since the recorder last entered `starting`, in which case this does nothing. So a failed
    /// start is reported exactly once, by the most specific call site that saw it.
    static func captureStartFailureIfUnreported(_ event: StaticString, error: Error?,
                                                _ data: Fields = [:]) {
        guard isOn else { return }
        let snapshot = ErrorSnapshot(error)
        let timestamp = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        queue.async {
            guard !startFailureCaptured else { return }
            sendFailure(event: event, stage: Stage.start.rawValue, error: snapshot, data: data,
                        timestamp: timestamp, uptime: uptime)
        }
    }

    // MARK: - Recording setup

    /// Notes facts about the recording that is being started — mode, permissions, the transport
    /// class of the devices in use — as numbers, booleans and tokens. Leaves a breadcrumb named
    /// `message`, and keeps the facts until the recorder is idle again, so that every event
    /// sent in between carries them: in `contexts.coachcam.recording_setup`, plus a searchable
    /// `setup.<key>` tag for each token.
    ///
    /// Breadcrumbs alone are not enough for this: only the newest 100 are kept, and a long
    /// check-in with many app switches scrolls the start of the recording out of that window.
    static func noteRecordingSetup(_ category: Category, _ message: StaticString, _ data: Fields) {
        guard isOn else { return }
        let timestamp = Date()
        queue.async {
            recordSetup(category, message, data, timestamp: timestamp)
        }
    }

    /// The same, for facts that cost something to read (permission status). `facts` is NOT run
    /// on the caller's thread: it runs on a background thread — and never at all when
    /// telemetry is off. The result takes its place in the telemetry queue at the moment of
    /// THIS call, so the facts are there before any event or state change requested after it,
    /// and a start that fails at once still carries them.
    ///
    /// The queue waits for the read, but for half a second at most (a permission lookup takes
    /// about 30 ms). Queued behind it is the app-hang pause for the recording that is starting,
    /// and that must never be held up by a slow lookup. If the read is slower than that, the
    /// facts for this recording are `deferred_facts: timed_out` and the late result is dropped.
    static func noteRecordingSetup(_ category: Category, _ message: StaticString,
                                   evaluating facts: @escaping @Sendable () -> Fields) {
        guard isOn else { return }
        let timestamp = Date()
        let result = DeferredFacts()
        DispatchQueue.global(qos: .utility).async {
            result.fulfil(facts())
        }
        queue.async {
            let data = result.wait(upTo: deferredFactsTimeout) ?? ["deferred_facts": .token("timed_out")]
            recordSetup(category, message, data, timestamp: timestamp)
        }
    }

    /// True once reporting has been started (also during an autotest run, when the SDK is live
    /// but sends nothing). For the few call sites that would otherwise read a device or the
    /// file system only to build a telemetry call: `if Telemetry.isEnabled { … }` keeps the
    /// app, with telemetry off, exactly as if those reads did not exist.
    static var isEnabled: Bool { isOn }

    // MARK: - Recorder state

    /// Records what the recorder is doing. Call from the main actor, at each state change, so
    /// the states arrive in the order they happened.
    ///
    /// Updates the `recording.state` tag (which is also on a crash report written while in
    /// that state), persists the state through the session marker (queued, not waited for),
    /// and pauses app-hang reporting for every state except `idle` — hang detection suspends
    /// all threads to take stack traces, which must never happen during a recording.
    ///
    /// It also keeps two clocks for the standard event context: seconds since the start was
    /// requested (`start_elapsed_s`, until the recording is running) and seconds since the
    /// recording began (`recording_elapsed_s`, wall clock, pauses included).
    static func setRecordingState(_ state: RecordingState) {
        guard isOn else { return }
        SessionMarker.shared.setRecordingState(state.rawValue)   // no-op during autotest
        let timestamp = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        queue.async {
            let previous = recordingState
            recordingState = state
            if previous == .idle, state != .idle {
                usbChangedDuringRecording = false   // a new recording is starting
            }
            switch state {
            case .starting:
                startFailureCaptured = false
                startRequestedUptime = uptime
                recordingBeganUptime = nil
                lastInterruption = nil            // a late disconnect now belongs to nothing
                interruptionFollowUpSent = false
            case .recording:
                // Not on a resume from `paused`: the clock runs from the first `recording`.
                if recordingBeganUptime == nil { recordingBeganUptime = uptime }
            case .idle:
                startRequestedUptime = nil
                recordingBeganUptime = nil
                recordingSetup = Fields()
            case .paused, .finalizing:
                break
            }
            if state == .idle {
                hangTracking.resume()
            } else {
                hangTracking.pause()
            }
            SentrySDK.configureScope { scope in
                scope.setTag(value: state.rawValue, key: "recording.state")
            }
            let crumb = Breadcrumb(level: .info, category: Category.recording.rawValue)
            crumb.message = "recorder state"
            crumb.timestamp = timestamp
            crumb.setData(value: state.rawValue, key: "state")
            SentrySDK.addBreadcrumb(crumb)
        }
    }

    // MARK: - Devices

    /// Notes that a camera or microphone was connected or disconnected. Kept in a small
    /// in-memory ring (the last 16 events) that is attached to failure and warning events as
    /// tokens and numbers only; also leaves a breadcrumb.
    ///
    /// Two reports of the same change that differ only in `wasInUse` (the app-lifetime
    /// observer and the recorder's) become one ring entry. A disconnect that arrives within
    /// 30 seconds AFTER a "recording interrupted" warning which knew of no disconnect sends
    /// one follow-up warning, "device disconnect confirmed after interruption".
    static func noteDeviceEvent(connected: Bool, media: Media, transport: Transport,
                                wasInUse: Bool) {
        guard isOn else { return }
        let timestamp = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        queue.async {
            // One unplugging of the device in use is reported twice: by the app-lifetime
            // observer (which cannot know whether the device was in use, and says no) and by
            // the recorder's own (which knows it was). The pair — same change, kind and
            // transport, a moment apart, disagreeing only about "in use" — is folded into ONE
            // ring entry that says in use, so the ring never shows two devices dropping where
            // one did, nor a slot that contradicts the next.
            let echoed: DeviceEvent? = deviceEvents.last.flatMap { last in
                let age = uptime - last.uptime
                let samePhysicalEvent = last.connected == connected && last.media == media
                    && last.transport == transport && last.wasInUse != wasInUse
                    && age >= 0 && age < deviceEchoWindow
                return samePhysicalEvent ? last : nil
            }
            if echoed != nil {
                deviceEvents[deviceEvents.count - 1].wasInUse = true
            } else {
                deviceEvents.append(DeviceEvent(connected: connected, media: media,
                                                transport: transport, wasInUse: wasInUse,
                                                uptime: uptime))
                if deviceEvents.count > maxDeviceEvents {
                    deviceEvents.removeFirst(deviceEvents.count - maxDeviceEvents)
                }
            }
            if transport == .usb, recordingState != .idle {
                usbChangedDuringRecording = true
            }

            if let echoed {
                // The first report already left its breadcrumb. Add one only when this report
                // is the one that knows the device was in use.
                if wasInUse, !echoed.wasInUse {
                    let crumb = Breadcrumb(level: .info, category: Category.device.rawValue)
                    crumb.message = connected ? "that device is the one in use"
                                              : "that device was the one in use"
                    crumb.timestamp = timestamp
                    crumb.setData(value: media.rawValue, key: "media")
                    crumb.setData(value: transport.rawValue, key: "transport")
                    SentrySDK.addBreadcrumb(crumb)
                }
            } else {
                let crumb = Breadcrumb(level: .info, category: Category.device.rawValue)
                crumb.message = connected ? "device connected" : "device disconnected"
                crumb.timestamp = timestamp
                crumb.setData(value: media.rawValue, key: "media")
                crumb.setData(value: transport.rawValue, key: "transport")
                crumb.setData(value: wasInUse, key: "was_in_use")
                SentrySDK.addBreadcrumb(crumb)
            }

            // A disconnect that arrives AFTER the interruption it explains. When the watchdog
            // (3 s microphone, 5 s camera) or a session error ends a recording before macOS
            // posts the disconnect, the "recording interrupted" event has already gone out
            // without it. Say so once, in a follow-up warning, whether the recorder is still
            // finalizing or already idle. Tokens and numbers only.
            if !connected, !interruptionFollowUpSent, let interruption = lastInterruption,
               !interruption.disconnectAlreadyKnown {
                let sinceInterruption = uptime - interruption.uptime
                if sinceInterruption >= 0, sinceInterruption <= interruptionFollowUpWindow {
                    interruptionFollowUpSent = true   // a webcam with a microphone drops twice
                    var fields: Fields = [
                        "media": .token(media.token),
                        "transport": .token(transport.token),
                        "since_interruption_s": .double(sinceInterruption),
                        "recorder_state": .token(recordingState.token),
                        "usb_flag_on_interruption": .bool(interruption.usbFlag)]
                    if let reason = interruption.reason { fields.set("interruption_reason", .token(reason)) }
                    if let source = interruption.source { fields.set("interruption_source", .token(source)) }
                    sendWarning(event: "device disconnect confirmed after interruption",
                                fingerprint: ["interruption-disconnect-confirmed",
                                              media.rawValue, transport.rawValue],
                                data: fields, timestamp: timestamp, uptime: uptime)
                }
            }
        }
    }

    /// The two fields that describe an `AVAssetWriter.Status` (pass `status.rawValue`):
    /// `writer_status` (the number) and `writer_status_name` (a token).
    static func writerStatusFields(rawValue: Int) -> Fields {
        let name: StaticString
        switch rawValue {
        case 0: name = "unknown"
        case 1: name = "writing"
        case 2: name = "completed"
        case 3: name = "failed"
        case 4: name = "cancelled"
        default: name = "other"
        }
        return ["writer_status": .int(rawValue), "writer_status_name": .token(name)]
    }

    // MARK: - Test triggers

    /// Sends a harmless test error, to prove events arrive (and are symbolicated).
    static func sendTestError() {
        guard isOn else { return }
        let snapshot = ErrorSnapshot(NSError(domain: "CoachCam.SentryTest", code: 1))
        let timestamp = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        queue.async {
            sendFailure(event: "sentry test error", stage: "test", error: snapshot, data: [:],
                        timestamp: timestamp, uptime: uptime)
        }
    }

    /// Crashes the app ON PURPOSE, to prove crash reports arrive. The report is written as the
    /// app dies and sent on the next launch. Does nothing unless reporting is live (so not
    /// without a DSN, not when opted out, not during an autotest run). The SDK cannot record a
    /// crash while a debugger is attached.
    static func sendTestCrash() {
        guard isReporting else { return }
        // Let queued breadcrumbs reach the SDK first, then crash on the main thread.
        queue.async {
            DispatchQueue.main.async { deliberateTestCrash() }
        }
    }

    // MARK: - For the launch scan (same module, not for call sites)

    /// True when events are really being sent: SDK started, not opted out, not an autotest run.
    static var isReporting: Bool { mode == .live }

    /// Runs `work` on the telemetry queue after every capture requested so far has been handed
    /// to the SDK (which keeps events on disk while offline).
    static func afterPendingCaptures(_ work: @escaping () -> Void) {
        queue.async(execute: work)
    }

    // MARK: - State

    private enum Mode {
        case off          // not started: every call is a no-op
        case live         // started and sending
        case suppressed   // autotest: started, sending nothing
    }

    private static let queue = DispatchQueue(label: "com.coachcam.telemetry", qos: .utility)

    private static let modeLock = NSLock()
    nonisolated(unsafe) private static var _mode: Mode = .off
    nonisolated(unsafe) private static var _startClaimed = false

    private static var mode: Mode {
        modeLock.lock(); defer { modeLock.unlock() }
        return _mode
    }

    private static var isOn: Bool { mode != .off }

    private static func setMode(_ newValue: Mode) {
        modeLock.lock(); defer { modeLock.unlock() }
        _mode = newValue
    }

    /// True the first time only: `start()` runs once per launch.
    private static func claimStart() -> Bool {
        modeLock.lock(); defer { modeLock.unlock() }
        if _startClaimed { return false }
        _startClaimed = true
        return true
    }

    // Everything below is only read and written on `queue`.
    nonisolated(unsafe) private static var recordingState: RecordingState = .idle
    nonisolated(unsafe) private static var usbChangedDuringRecording = false
    nonisolated(unsafe) private static var deviceEvents: [DeviceEvent] = []
    private static let maxDeviceEvents = 16
    /// `systemUptime` when the recorder last entered `starting` / first entered `recording`.
    nonisolated(unsafe) private static var startRequestedUptime: TimeInterval?
    nonisolated(unsafe) private static var recordingBeganUptime: TimeInterval?
    /// A stage-`start` failure has been sent since the recorder last entered `starting`.
    nonisolated(unsafe) private static var startFailureCaptured = false
    /// Facts about the recording in flight (`noteRecordingSetup`); emptied when idle again.
    nonisolated(unsafe) private static var recordingSetup = Fields()
    /// The last "recording interrupted" warning of the current / most recent recording, and
    /// whether its one follow-up has been sent. Both reset when a new recording starts.
    nonisolated(unsafe) private static var lastInterruption: Interruption?
    nonisolated(unsafe) private static var interruptionFollowUpSent = false
    /// How long after an interruption a disconnect still counts as its explanation (macOS can
    /// take ten seconds or more to post it).
    private static let interruptionFollowUpWindow: TimeInterval = 30
    /// Two reports of one device change arrive within microseconds of each other.
    private static let deviceEchoWindow: TimeInterval = 1
    /// The longest the telemetry queue waits for `noteRecordingSetup(_:_:evaluating:)`.
    private static let deferredFactsTimeout: TimeInterval = 0.5

    private struct DeviceEvent {
        let connected: Bool
        let media: Media
        let transport: Transport
        var wasInUse: Bool
        let uptime: TimeInterval
    }

    /// What is remembered about a "recording interrupted" warning, for the follow-up.
    private struct Interruption {
        let uptime: TimeInterval
        /// A camera / microphone disconnect had already been noted in this recording.
        let disconnectAlreadyKnown: Bool
        /// `usb.changed_during_recording` as it went out on the warning.
        let usbFlag: Bool
        let reason: StaticString?
        let source: StaticString?
    }

    /// What `beforeSend` stamps on every event: the anonymous device id and the two Mac tags.
    private struct EventIdentity {
        let userID: String
        let chip: String
        let translated: String
    }

    /// Domain and code of an error (and of its underlying error) — nothing else. Built on the
    /// caller's thread; the original error is dropped straight after.
    private struct ErrorSnapshot {
        let domain: String
        let code: Int
        let underlyingDomain: String?
        let underlyingCode: Int?

        init?(_ error: Error?) {
            guard let error else { return nil }
            let ns = error as NSError
            domain = TelemetryScrubber.sanitizedErrorDomain(ns.domain)
            code = ns.code
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
                underlyingDomain = TelemetryScrubber.sanitizedErrorDomain(underlying.domain)
                underlyingCode = underlying.code
            } else {
                underlyingDomain = nil
                underlyingCode = nil
            }
        }
    }

    // MARK: - Building events (on `queue`)

    /// The breadcrumb and the kept facts behind both `noteRecordingSetup` calls.
    private static func recordSetup(_ category: Category, _ message: StaticString, _ data: Fields,
                                    timestamp: Date) {
        recordingSetup = recordingSetup.merging(data).compacted()
        let crumb = Breadcrumb(level: .info, category: category.rawValue)
        crumb.message = message.description
        crumb.timestamp = timestamp
        for (key, value) in data.jsonObject {
            crumb.setData(value: value, key: key)
        }
        SentrySDK.addBreadcrumb(crumb)
    }

    private static func sendWarning(event: StaticString, fingerprint: [String], data: Fields,
                                    timestamp: Date, uptime: TimeInterval) {
        let name = event.description
        let sentryEvent = Event(level: .warning)
        sentryEvent.timestamp = timestamp
        sentryEvent.message = SentryMessage(formatted: name)
        if !fingerprint.isEmpty {
            sentryEvent.fingerprint = fingerprint
        }
        var tags = eventTags(data: data)
        tags["event"] = name
        tags["usb.changed_during_recording"] = usbChangedDuringRecording ? "true" : "false"
        sentryEvent.tags = tags
        sentryEvent.context = ["coachcam": standardContext(uptime: uptime, data: data)]

        // Remember an interruption, so that a device disconnect which macOS posts only
        // afterwards can still be tied to it (see `noteDeviceEvent`).
        if fingerprint.first == "recording-interrupted" {
            let recordingStarted = startRequestedUptime ?? 0
            lastInterruption = Interruption(
                uptime: uptime,
                disconnectAlreadyKnown: deviceEvents.contains {
                    !$0.connected && $0.uptime >= recordingStarted
                },
                usbFlag: usbChangedDuringRecording,
                reason: data.token(forKey: "reason"),
                source: data.token(forKey: "source"))
        }

        SentrySDK.capture(event: sentryEvent)
    }

    private static func sendFailure(event: StaticString, stage: String, error: ErrorSnapshot?,
                                    data: Fields, timestamp: Date, uptime: TimeInterval) {
        let name = event.description
        let sentryEvent = Event(level: .error)
        sentryEvent.timestamp = timestamp
        sentryEvent.message = SentryMessage(formatted: name)

        // A fresh description built from domain + code only. The original error object — with
        // its description and userInfo — never reaches the SDK.
        var summary = "no error object"
        if let error {
            summary = "\(error.domain) \(error.code)"
            if let domain = error.underlyingDomain, let code = error.underlyingCode {
                summary += " (underlying \(domain) \(code))"
            }
        }
        let exception = Exception(value: summary, type: name)
        let mechanism = Mechanism(type: error == nil ? "generic" : "NSError")
        mechanism.handled = true
        if let error {
            let meta = MechanismContext()
            meta.error = SentryNSError(domain: error.domain, code: error.code)
            mechanism.meta = meta
        }
        exception.mechanism = mechanism
        sentryEvent.exceptions = [exception]

        // A capture-stage failure while nothing is being recorded: the recorder is idle, or the
        // start that is in flight has already been reported as failed. (A start that fails
        // leaves the microphone session running; its next buffer finds the dead writer and
        // reports it again.) Still sent — it is how that leftover session becomes visible —
        // but marked and grouped apart, so it can never be counted as a recording that was
        // lost part-way through.
        let outsideRecording = stage == Stage.capture.rawValue
            && (recordingState == .idle || (recordingState == .starting && startFailureCaptured))

        // Every failure is captured from this queue, so the stack trace is always the same and
        // must not decide grouping. Group by what failed, where, and with which error instead.
        sentryEvent.fingerprint = [outsideRecording ? "coachcam-failure-outside-recording"
                                                    : "coachcam-failure",
                                   name, stage,
                                   error?.domain ?? "none",
                                   error.map { String($0.code) } ?? "none"]

        var tags = eventTags(data: data)
        tags["event"] = name
        tags["stage"] = stage
        if outsideRecording {
            tags["outside_recording"] = "true"
        }
        tags["usb.changed_during_recording"] = usbChangedDuringRecording ? "true" : "false"
        if let error {
            tags["error.domain"] = error.domain
            tags["error.code"] = String(error.code)
        }
        sentryEvent.tags = tags
        if stage == Stage.start.rawValue {
            startFailureCaptured = true   // see `captureStartFailureIfUnreported`
        }

        var context = standardContext(uptime: uptime, data: data)
        context["stage"] = stage
        if let error {
            context["error_domain"] = error.domain
            context["error_code"] = error.code
            if let domain = error.underlyingDomain, let code = error.underlyingCode {
                context["underlying_error_domain"] = domain
                context["underlying_error_code"] = code
            }
        }
        sentryEvent.context = ["coachcam": context]

        SentrySDK.capture(event: sentryEvent)
    }

    /// An event's tags: a `setup.<key>` tag for each token among the facts noted about the
    /// recording in flight, then the call site's own (tokens, booleans, error domain / code).
    private static func eventTags(data: Fields) -> [String: String] {
        var tags: [String: String] = [:]
        if recordingState != .idle {
            for (key, value) in recordingSetup.tokenTags {
                tags["setup." + key] = value
            }
        }
        for (key, value) in data.tags {
            tags[key] = value
        }
        return tags
    }

    /// The standard failure context plus the call site's own fields.
    private static func standardContext(uptime: TimeInterval, data: Fields) -> [String: Any] {
        var context: [String: Any] = data.jsonObject
        context["recording_state"] = recordingState.rawValue
        context["usb_changed_during_recording"] = usbChangedDuringRecording
        if let freeGB = freeDiskGB() {
            context["free_disk_gb"] = freeGB
        }
        if recordingState != .idle {
            // How far into the recording (or into its start) this happened. `uptime` was read
            // on the caller's thread when the event was requested.
            if let began = recordingBeganUptime {
                context["recording_elapsed_s"] = rounded(max(0, uptime - began), places: 1)
            } else if let requested = startRequestedUptime {
                context["start_elapsed_s"] = rounded(max(0, uptime - requested), places: 1)
            }
            let setup = recordingSetup.jsonObject
            if !setup.isEmpty {
                context["recording_setup"] = setup
            }
        }
        context["device_events"] = deviceEvents.map { event -> [String: Any] in
            ["change": event.connected ? "connected" : "disconnected",
             "media": event.media.rawValue,
             "transport": event.transport.rawValue,
             "was_in_use": event.wasInUse,
             "seconds_ago": rounded(max(0, uptime - event.uptime), places: 1)]
        }
        return context
    }

    /// Free space on the volume that holds the recordings, in GB to one decimal.
    private static func freeDiskGB() -> Double? {
        guard let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first,
              let values = try? movies.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return rounded(Double(bytes) / 1_000_000_000, places: 1)
    }

    private static func rounded(_ value: Double, places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (value * factor).rounded() / factor
    }

    private static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    @inline(never)
    private static func deliberateTestCrash() {
        SentrySDK.crash()
    }

    // MARK: - Scrubbing what the SDK collected by itself

    /// `beforeSend`: runs for every event, including crash reports from the previous run.
    /// Debug ids, image addresses and instruction addresses are not touched, so symbolication
    /// keeps working.
    private static func scrubbed(_ event: Event, identity: EventIdentity) -> Event {
        if let message = event.message {
            let clean = SentryMessage(formatted: TelemetryScrubber.scrub(message.formatted))
            clean.message = message.message.map { TelemetryScrubber.scrub($0) }
            clean.params = message.params?.map { TelemetryScrubber.scrub($0) }
            event.message = clean
        }

        for exception in event.exceptions ?? [] {
            exception.value = exception.value.map { TelemetryScrubber.scrub($0) }
            exception.type = exception.type.map { TelemetryScrubber.scrub($0) }
            if let mechanism = exception.mechanism {
                mechanism.desc = mechanism.desc.map { TelemetryScrubber.scrub($0) }
                mechanism.data = nil   // an NSError's userInfo: NSFilePath, NSURL, …
            }
            scrubFrames(exception.stacktrace)
        }
        for thread in event.threads ?? [] {
            thread.name = thread.name.map { TelemetryScrubber.scrub($0) }
            scrubFrames(thread.stacktrace)
        }
        scrubFrames(event.stacktrace)

        for image in event.debugMeta ?? [] {
            image.codeFile = image.codeFile.map { TelemetryScrubber.scrubImagePath($0) }
        }

        if var context = event.context {
            context.removeValue(forKey: "user info")   // a second copy of an error's userInfo
            for (key, value) in context {
                if let clean = TelemetryScrubber.scrubValue(value) as? [String: Any] {
                    context[key] = clean
                }
            }
            // The SDK's own "app" context holds `device_app_hash`: a hash of this Mac's
            // network hardware address, its model and the bundle id. That is a second,
            // hardware-derived identifier; the 8-character device id is the only one we send.
            if var app = context["app"] {
                app.removeValue(forKey: "device_app_hash")
                context["app"] = app
            }
            event.context = context
        }

        for crumb in event.breadcrumbs ?? [] {
            _ = scrubbed(crumb)
        }

        if let extra = event.extra {
            event.extra = TelemetryScrubber.scrubValue(extra) as? [String: Any]
        }
        // The two Mac tags come from the scope. An event the SDK builds WITHOUT the scope (a
        // MetricKit diagnostic recorded by an earlier run of the app) has none, so they are
        // filled in here.
        var tags = (event.tags ?? [:]).mapValues { TelemetryScrubber.scrub($0) }
        if tags["mac.chip"] == nil { tags["mac.chip"] = identity.chip }
        if tags["mac.translated"] == nil { tags["mac.translated"] = identity.translated }
        event.tags = tags

        event.request = nil
        event.serverName = nil

        // Identity on an event is the anonymous 8-character device id and nothing else. It is
        // set outright, not trimmed: an event built without the scope has no user, and the SDK
        // then fills in its own random per-install id — one Mac would show up as two users.
        // (Release-health SESSION updates are not events and do not pass through here: they
        // carry that random per-install id as `did`. It is not derived from anything on the Mac.)
        event.user = User(userId: identity.userID)
        return event
    }

    /// `beforeBreadcrumb` (and the breadcrumbs already on an event).
    private static func scrubbed(_ crumb: Breadcrumb) -> Breadcrumb {
        crumb.message = crumb.message.map { TelemetryScrubber.scrub($0) }
        for (key, value) in crumb.data ?? [:] {
            crumb.setData(value: TelemetryScrubber.scrubValue(value), key: key)
        }
        return crumb
    }

    /// A frame's `package` is the path of the binary it belongs to — under the home folder
    /// when the app runs from there.
    private static func scrubFrames(_ stacktrace: SentryStacktrace?) {
        for frame in stacktrace?.frames ?? [] {
            frame.package = frame.package.map { TelemetryScrubber.scrubImagePath($0) }
        }
    }

    // MARK: - App-hang reporting switch

    /// `SentrySDK.pauseAppHangTracking()` / `resumeAppHangTracking()` are marked deprecated in
    /// sentry-cocoa 9.35.0 (app-hang tracking is removed in v10) but are the only way to pause
    /// hang reporting during a recording. Calling them through a protocol whose implementation
    /// carries the same deprecation mark keeps the build free of a warning we cannot act on.
    private static let hangTracking: HangTrackingSwitch = SDKHangTrackingSwitch()
}

/// Facts that are being read on another thread, waited for with a time limit
/// (`Telemetry.noteRecordingSetup(_:_:evaluating:)`).
private final class DeferredFacts: @unchecked Sendable {
    private let lock = NSLock()
    private var fields: Telemetry.Fields?
    private let ready = DispatchSemaphore(value: 0)

    func fulfil(_ value: Telemetry.Fields) {
        lock.lock()
        fields = value
        lock.unlock()
        ready.signal()
    }

    /// The facts, or nil if they did not arrive within `seconds`.
    func wait(upTo seconds: TimeInterval) -> Telemetry.Fields? {
        _ = ready.wait(timeout: .now() + seconds)
        lock.lock(); defer { lock.unlock() }
        return fields
    }
}

private protocol HangTrackingSwitch {
    func pause()
    func resume()
}

private struct SDKHangTrackingSwitch: HangTrackingSwitch {
    @available(*, deprecated, message: "Wraps the SDK's deprecated app-hang pause API; removed in sentry-cocoa v10.")
    func pause() { SentrySDK.pauseAppHangTracking() }

    @available(*, deprecated, message: "Wraps the SDK's deprecated app-hang resume API; removed in sentry-cocoa v10.")
    func resume() { SentrySDK.resumeAppHangTracking() }
}

// MARK: - Conversions

extension Telemetry.RecordingState {
    /// The state as a compile-time constant token.
    var token: StaticString {
        switch self {
        case .idle: return "idle"
        case .starting: return "starting"
        case .recording: return "recording"
        case .paused: return "paused"
        case .finalizing: return "finalizing"
        }
    }
}

private extension Telemetry.Media {
    /// The media type as a compile-time constant token.
    var token: StaticString {
        switch self {
        case .video: return "video"
        case .audio: return "audio"
        }
    }
}

private extension Telemetry.Level {
    var sentryLevel: SentryLevel {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .warning
        case .error: return .error
        }
    }
}

private extension Telemetry.Value {
    /// The JSON value sent in a breadcrumb's data or an event's context.
    var jsonValue: Any? {
        switch self {
        case .int(let value): return value
        case .double(let value):
            // JSON has no NaN / infinity; three decimals are plenty for seconds, MB and rates.
            guard value.isFinite else { return nil }
            return (value * 1_000).rounded() / 1_000
        case .bool(let value): return value
        case .token(let value): return value.description
        case .errorDomain(let value): return TelemetryScrubber.sanitizedErrorDomain(value.raw)
        case .errorCode(let value): return value
        }
    }

    /// The searchable tag for a value that is one of a small set (tokens, booleans, error
    /// domain / code). Measurements are not tags.
    var tagValue: String? {
        switch self {
        case .int, .double: return nil
        case .bool(let value): return value ? "true" : "false"
        case .token(let value): return value.description
        case .errorDomain(let value): return TelemetryScrubber.sanitizedErrorDomain(value.raw)
        case .errorCode(let value): return String(value)
        }
    }
}

private extension Telemetry.Fields {
    var jsonObject: [String: Any] {
        var object: [String: Any] = [:]
        for pair in pairs {
            if let value = pair.value.jsonValue {
                object[pair.key.description] = value
            }
        }
        return object
    }

    var tags: [String: String] {
        var tags: [String: String] = [:]
        for pair in pairs {
            if let value = pair.value.tagValue {
                tags[pair.key.description] = value
            }
        }
        return tags
    }

    /// The constant token stored under `key` (its last value), if there is one.
    func token(forKey key: String) -> StaticString? {
        for pair in pairs.reversed() where pair.key.description == key {
            if case .token(let value) = pair.value { return value }
            return nil
        }
        return nil
    }

    /// Only the constant tokens, as tags (for the recording-setup facts: their booleans and
    /// numbers stay in the context, so an event does not sprout dozens of tags).
    var tokenTags: [String: String] {
        var tags: [String: String] = [:]
        for pair in pairs {
            if case .token(let value) = pair.value {
                tags[pair.key.description] = value.description
            }
        }
        return tags
    }

    /// The same fields with each key once (its last value wins), so fields that are merged
    /// over and over cannot grow without limit.
    func compacted() -> Telemetry.Fields {
        var position: [String: Int] = [:]
        var result = Telemetry.Fields()
        for pair in pairs {
            let key = pair.key.description
            if let index = position[key] {
                result.pairs[index] = pair
            } else {
                position[key] = result.pairs.count
                result.pairs.append(pair)
            }
        }
        return result
    }
}
