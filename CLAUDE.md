# CoachCap — macOS Recording App for Fitness Coaches

## Purpose
Native macOS app (Swift/SwiftUI, macOS 14+). Records screen + face-cam composited into a single
H.264 MP4 small enough to drag straight into WhatsApp Desktop. Recording, compositing, and export
are fully on-device — no cloud, no accounts for the core workflow.

The app makes outbound HTTPS calls to `api.lemonsqueezy.com` for subscription license
activation / validation / deactivation (see Licensing below). A 30-day offline grace window keeps
the app fully functional without a network connection; a confirmed-inactive subscription revokes
access on the next successful check.

## Licensing
Lemon Squeezy monthly subscription license keys (store 406047, variant 1784319), one activation
per Mac. `Models/DeviceIdentity.swift` derives a stable hardware UUID (IOKit `IOPlatformUUID`) sent
as `instance_name`, which is what enforces one-Mac-per-key. `Models/LemonSqueezyClient.swift` wraps
the activate/validate/deactivate endpoints and rejects responses whose `meta.store_id` /
`meta.variant_id` don't match CoachCam. `Models/License.swift` (`LicenseManager`) owns unlock state:
activate on key entry, validate on launch (non-blocking), and the 30-day grace logic. A confirmed
"not active" overrides grace and locks immediately; an unreachable server rides the grace window at
full functionality. License key, instance id, and last-validated timestamp live in the Keychain
(`Models/Keychain.swift`), never UserDefaults. The license/settings UI (`UI/LicenseView.swift`)
includes a "Deactivate this device" button to free the activation slot when switching Macs.
This is a timestamp-trust model (not cryptographically signed); `LicenseManager` isolates the
validation call so a signed-token provider could replace it later without UI changes.

## Folder Structure
```
CoachCap/
  Recording/     ScreenCaptureKit stream, pause/resume logic
  Camera/        AVCaptureSession face-cam capture + preview
  Compositor/    CoreImage frame-level PiP compositing
  Export/        AVAssetWriter H.264/AAC pipeline, auto-compress
  PhotoTool/     Before/after JPEG stitcher
  UI/            SwiftUI views (one-window, big-button design)
  Models/        AppState (ObservableObject), RecordingConfig
```

## Key Data Flow
```
SCStream (screen frames) ──────────────────────────────────────────────┐
                                                                        ▼
AVCaptureSession (camera frames) ──► FrameCompositor ──► AVAssetWriter ──► .mp4
                                       (draws PiP at
                                        normalised rect,
                                        every frame)
SCStream (system audio) ────────────────────────────────► AVAssetWriter
AVCaptureSession (microphone) ──────────────────────────► AVAssetWriter
```

## PiP Position
Stored as a **normalised CGRect** (origin and size in 0–1 space).
Burned into every frame by FrameCompositor. Draggable in the live preview overlay.

## Audio Strategy
- System audio: `SCStreamConfiguration.capturesAudio = true`
- Microphone: separate `AVCaptureSession` with `AVCaptureAudioDataOutput`
- Both written as separate `AVAssetWriterInput` tracks (MP4 supports multi-track audio;
  players mix automatically).

## Permissions
| Resource | Mechanism |
|---|---|
| Camera | `NSCameraUsageDescription` in Info.plist — system prompts on first use |
| Microphone | `NSMicrophoneUsageDescription` in Info.plist — system prompts on first use |
| Screen | User grants in System Settings → Privacy & Security → Screen Recording on first run |

## Error Tracking (Sentry)
Crash and error reporting goes to Sentry: sentry-cocoa **9.35.0**, pinned exactly in `project.yml`,
product `SentrySPM` (compiled from source and linked into the app binary, so there is no extra
framework to sign or notarise). When reporting is on, the app makes outbound HTTPS calls to the
Sentry host named in the DSN.

**One wrapper.** `Models/Telemetry.swift` is the ONLY file that imports the SDK (`import SentrySwift`).
Everything else calls it:
- `Telemetry.start()` — first statement of `CoachCapApp.init`, ahead of Sparkle
- `Telemetry.breadcrumb(_:_:_:level:)` — a constant message plus numbers / booleans / tokens
- `Telemetry.captureFailure(_:stage:error:_:)` — error event; keeps only the error's domain + code
- `Telemetry.captureWarning(_:fingerprint:_:)` — warning event, grouped by the fingerprint
- `Telemetry.captureStartFailureIfUnreported(_:error:_:)` — the UI's catch-all for a start that threw;
  sends only if `RecordingSession.start()` did not already report that failure itself
- `Telemetry.setRecordingState(_:)` — `idle` / `starting` / `recording` / `paused` / `finalizing`
- `Telemetry.noteRecordingSetup(_:_:_:)` — facts about the recording being started (mode, permissions,
  device transport classes); a breadcrumb, and attached to every event until the recorder is idle again.
  `Telemetry.noteRecordingSetup(_:_:evaluating:)` is the same for facts that cost something to read
  (permission status): its closure runs on a background thread, never on the caller's thread and not at
  all when telemetry is off; the result keeps its place in the telemetry queue, so a start that fails at
  once still carries the facts (the queue waits at most half a second for the read, so the app-hang
  pause queued behind it is never held up; slower than that and the facts read `deferred_facts:timed_out`)
- `Telemetry.noteDeviceEvent(connected:media:transport:wasInUse:)` — camera / mic plugged or unplugged
- `Telemetry.isEnabled` — wrap a call site in `if Telemetry.isEnabled { … }` when it would otherwise read
  a device or the file system only to build a telemetry call, so that with telemetry off nothing is read

An error's domain is passed as `.errorDomain(Telemetry.ErrorDomain(error))` — it can only be built from
an error object, never from a string.

`Models/TelemetryCapture.swift` turns an `AVCaptureDevice` or an authorisation status into a constant
token (transport class, `authorized` / `denied` / …) — the only place device objects meet telemetry.

**In the recorder.** `Recording/RecordingSession.swift` calls telemetry beside the existing code and never
instead of it: the `appendErrorLog` lines are untouched (autotest greps them). Its telemetry-only helpers
sit in one extension at the bottom of the file (`telemetry…`). On the capture queues there are exactly two
calls, both once per recording: the first video frame written, and the once-only writer-failure latch.
Recorder state: `starting` when `start()` begins, `recording` when it has succeeded, `paused` / `recording`
on pause / resume, `finalizing` when `finalizeWriter()` begins and `idle` when it has finished (every
outcome, every caller); a start that throws is put back to `idle` by `RecordingView`'s catch.

**Privacy rule (hard).** No user content leaves the Mac. Never pass a path, URL, file / folder /
client / device / host name, licence key, transcript text, search query, `error.localizedDescription`
or an error's `userInfo` into a telemetry call. The API is typed to enforce this (`StaticString`
messages and keys, closed `Telemetry.Value` enum with no free-text case) — do not weaken the types.
`Models/TelemetryScrubber.swift` is the second line of defence: in `beforeSend` / `beforeBreadcrumb` it
redacts home-folder paths and recording-style file names from text the SDK collects by itself. Below the
home folder only the app's own data folders stay visible (as the folder itself, nothing under it); any
other home path becomes `/Users/<redacted>/<path>`.

**Identity.** Every event carries the first 8 characters of `DeviceIdentity.hardwareUUID` as its user id
and nothing else: `beforeSend` sets the user outright (so an event the SDK builds without the scope, such
as a MetricKit diagnostic from an earlier run, gets the same id) and removes `device_app_hash` from the
SDK's `app` context (a hash of the Mac's network hardware address, model and bundle id that the SDK adds
by itself). `sendDefaultPii` is off. One thing is outside this: release-health **session** updates are not
events and do not pass through `beforeSend`; they carry a random per-install id (`did`) that the SDK makes
up and keeps in its cache folder. It is not derived from anything on the Mac and cannot be changed from
the app (session tracking stays on, as specified).

**What is reported.** Crashes; app hangs over 5 s (hang tracking is paused from the moment a recording
start begins until finalize has finished); MetricKit diagnostics; AVAssetWriter failures and start
failures as errors (stage `start` / `capture` / `finalize` / `save`); interrupted recordings, audio
anomalies at finalize, and a finalize that is asked for again while still running, as warnings; leftover
recordings found at launch; a previous session that did not exit cleanly. Events carry numbers and tokens
only: error domain + code, writer status, seconds into the recording, free disk space, per-track sample
counts, the recording setup (mode, permissions, camera / mic transport class), Apple Silicon / Intel /
Rosetta, and recent camera / mic connect and disconnect events by transport class (built-in / USB /
Bluetooth / Continuity-or-virtual).
Uncaught-NSException reporting and swizzling are deliberately OFF (turning them on would make the app
crash where it survives today); network, file-IO, Core Data and performance tracing are off.

**Reading the events.**
- `usb.changed_during_recording` only says that a USB camera / mic connect or disconnect notification
  had ALREADY arrived in that recording when the event was built. macOS can post a disconnect ten seconds
  or more after the device stops delivering, so when the watchdog (3 s mic, 5 s camera) ends the recording
  first, "recording interrupted" goes out with the tag false. The signature of a pulled device is then
  `reason:watchdog_microphone` / `watchdog_camera` with `setup.mic_transport:usb` /
  `setup.camera_transport:usb`. If the disconnect does arrive within 30 s, ONE follow-up warning is sent:
  "device disconnect confirmed after interruption" (media, transport, seconds since the interruption,
  the interruption's reason and source).
- One unplugging of the device in use is reported by two observers (`CameraManager`'s, which says "not in
  use", and the recorder's, which knows). `Telemetry.noteDeviceEvent` folds the pair into one
  `device_events` entry that says in use.
- A "writer failed mid-recording" event tagged `outside_recording:true` is NOT a lost check-in: nothing was
  being recorded. It is the echo of a start that failed (the microphone session that start leaves running
  finds the dead writer). It is grouped apart from real mid-recording failures.
- "previous session did not exit cleanly" is filed under the build that FOUND it. After an update,
  `previous_build_differs:true` marks the ones where the build that died was the previous one
  (`previous_build` in the `coachcam` context).

**When nothing is sent.**
- No DSN (or a malformed one) in Info.plist → the SDK never starts and every `Telemetry` call is a no-op.
- Opt-out: `defaults write com.coachcam.app shareDiagnostics -bool false` → the SDK never starts.
- Autotest: launched with `-autotest …`, or with any `simulate*StallAfterSeconds` above zero → the SDK
  starts (environment `autotest`) but sends nothing; the launch scan and clean-exit check are skipped.
  Two consequences for the Mac that runs the harness: a crash report waiting from an earlier normal run is
  thrown away unsent by an autotest launch, and a crash DURING an autotest run is dropped by the next
  normal launch (it still carries the `autotest` environment). So after a real or a test crash, open
  CoachCam normally once before running `bash /Users/jake/Documents/ClaudeCode/CoachCap/autotest.sh` or
  arming a `simulate…` key.
- A second copy of the app opened while one is already running (from a DMG, `open -n`, a Debug run beside
  the installed app) still reports its own errors, but leaves the clean-exit marker and the launch scan
  to the copy that was opened first.

**DSN — never committed (this repo is public).** Build setting `SENTRY_DSN` → Info.plist key `SentryDSN`.
The tracked default in `Config/CoachCam.xcconfig` is empty; the real value lives in the untracked file
`/Users/jake/Documents/ClaudeCode/CoachCap/Config/Secrets.local.xcconfig`, written by
`bash /Users/jake/Documents/ClaudeCode/CoachCap/Scripts/set_sentry_dsn.sh "<DSN>"` (it handles the
xcconfig trap where `//` starts a comment). Never put the DSN or `SENTRY_DSN` under `settings` in
`project.yml`. Release name = `CoachCam@<version>+<build>`; environment = `production` (Release),
`debug` (Debug) or `autotest`.

**Clean-exit marker.** `Models/SessionMarker.swift` keeps
`/Users/<user>/Library/Application Support/CoachCam/session-state.json`: `running` at launch, `clean` on
`NSApplication.willTerminateNotification`. A launch that still finds `running` sends "previous session
did not exit cleanly" with the last recorder state. The file also remembers the recording in flight
(local only, never sent) so the next launch can recognise a truncated file. There is one in-flight slot:
when a new recording starts while an earlier one was never finalised (its window was closed mid-recording),
the earlier path moves to the never-finalised list instead of being forgotten, and a finalize names the
recording it finished (`recordingFinalized(path:)`) so it never clears a newer recording's slot.

**Launch scan.** `Models/RecordingsHealthScan.swift`, scheduled by `Telemetry.start()`, off the main
thread: one warning per leftover `.mp4` under `/Users/<user>/Movies/CoachCap` (at most 20 per launch) with
its class (`empty`, `empty_unfinished`, `unfinished`, `truncated`, `workfile_empty`), age, size and whether
it sits in a `WC yyyy-MM-dd` week folder — never a file or folder name. Each file is reported once
(UserDefaults key `reportedBadRecordings`, local only).

**Debug symbols (dSYMs).** `Scripts/upload_dsyms.sh` runs `sentry-cli debug-files upload` (no source code).
It is the last build phase of Release archives ("Upload dSYMs to Sentry") and runs again from
`make_test_dmg.sh` / `make_release_dmg.sh` after stapling (`Scripts/release_common.sh`), which also keep
a copy in `build/dsyms/<version>-<build>/`. It can never fail a build: it skips with a `note:` when
`sentry-cli`, the upload token or the organisation / project are missing. Those come from
`SENTRY_AUTH_TOKEN` / `SENTRY_ORG` / `SENTRY_PROJECT`, or from the file `/Users/jake/.sentryclirc`
(`[auth]` `token=…`, `[defaults]` `org=…` and `project=…`) — never from this repo. That file's name starts
with a dot, so Finder hides it: open it with `open -e /Users/jake/.sentryclirc`. Both DMG scripts refuse
to package an app that is not the expected build or has no well-formed `SentryDSN`
(`ALLOW_NO_DSN=1` overrides the DSN check). Off switch for one archive that must not touch the network:
add `SENTRY_SKIP_DSYM_UPLOAD=YES` to the end of the `xcodebuild archive` command; the build phase then
prints a `note:` and uploads nothing, and the DMG script uploads the same symbols after stapling.

**Verifying that reports arrive.**
- Debug builds: menu **Debug → Send Sentry test error / Send Sentry test crash** (`#if DEBUG` only).
  A crash is not recorded while Xcode's debugger is attached — run the built app on its own for that.
- Release / notarised builds: quit CoachCam, then run
  `open -a /Applications/CoachCam.app --args -sentryTestError YES` (or `-sentryTestCrash YES`).
  The test error shows up in Sentry as "sentry test error"; a test crash is sent the next time the app
  is opened NORMALLY (not through `autotest.sh`, and with no `simulate…StallAfterSeconds` key set — a
  test-run launch discards the waiting crash report). The flags are read from the launch arguments only,
  so a `defaults write` can never trigger them.
- In a Debug build with reporting off (no DSN, opted out, or a test run) the two Debug menu items are
  greyed out and a line above them says so.

**Rules when changing this.**
- Add telemetry calls BESIDE the existing `appendErrorLog(...)` lines; never reword, move or remove those
  (`autotest.sh` greps their exact text).
- On capture queues: once per event, never per frame or per buffer, never while `captureLock` is held.
- The files the test target compiles standalone (`VideoTrimmer`, `VideoTranscriber`, `RecordingConfig`,
  `DisplayList`, `PhotoMatching`, `PhotoStitcher`, `FrameCompositor`) must not reference `Telemetry`; the export / trim /
  transcribe code is not instrumented.
- `TelemetryScrubber.swift` and `SessionMarker.swift` are Foundation-only and are also compiled into the
  test target (`Tests/TelemetryScrubberTests.swift`, `Tests/SessionMarkerTests.swift`).
- New Swift files, packages, Info.plist keys and build phases go in `project.yml`, followed by `xcodegen generate`.

## Build Settings (project.pbxproj)
- `MACOSX_DEPLOYMENT_TARGET = 14.0`
- `SWIFT_VERSION = 5.9`
- `ENABLE_HARDENED_RUNTIME = YES` (required for camera/mic entitlements)
- `CODE_SIGN_ENTITLEMENTS = CoachCap/CoachCap.entitlements`
- Sandbox: **off** (personal-use, non-App-Store)

## Export Target
- Video: H.264, 1080p @ 4 Mbps or 720p @ 2 Mbps (auto-selected by RecordingConfig)
- Audio: AAC 128 kbps
- File name: `ClientName_YYYY-MM-DD[_n].mp4` in `~/Movies/CoachCap/`

## Feature Status
- [x] Screen + face-cam recording end-to-end
- [x] PiP drag in preview, normalised rect burned into frames
- [x] Camera/mic source pickers with device enumeration
- [x] Webcam-only (talking-head) mode — the screen capture still runs as the frame clock, but `FrameCompositor.webcamOnly` draws ONLY the camera, full-frame with square corners (the rounded mask is for the corner PiP only; `Tests/FrameCompositorTests.swift` pins what each mode's frame contains). The float cam never suppresses the camera in this mode (build 84: `RecordingSession.handleVideoFrame` — in screen modes the float cam window is itself in the recording, so the burned-in PiP is dropped; webcam-only records no screen, so dropping it left black video).
- [x] Pause/resume (track cumulative paused duration, skip frames during pause)
- [x] Before/after photo stitcher (PhotoStitcher)
- [x] In-app "how it works" guide (`UI/HelpGuideView.swift`) — "?" button in the top bar + auto-shown once on first launch (`@AppStorage("hasSeenGuide")`); covers recording, smart-match keys, WhatsApp import, and Screen Recording / Full Disk Access permission steps with deep-link buttons
- [x] Auto-backup: every finished recording also copied to a coach-chosen folder (point at iCloud Drive / Google Drive / Dropbox for Loom-style auto-upload with coach-owned storage). `BackupManager` in `Models/BrandingStore.swift`, hooked on `lastSavedURL` change AFTER finalize — never touches the recording pipeline. Status shown in the saved banner.
- [x] Custom branding (`Models/BrandingStore.swift` + `UI/SettingsSheet.swift`, ⚙ in the top bar): coach logo + primary/secondary colours, applied to CLIENT-facing output only — logo burned top-right of recordings (via `RecordingConfig.brandLogoCG` → `FrameCompositor.brandLogo`, snapshotted at start, video frames only) and logo + colours on stitched before/after exports (`PhotoStitcher.Options.logo`, header/divider colours with auto contrast).
- [x] Trim editor (`UI/TrimEditorView.swift` + `Export/VideoTrimmer.swift`): "edit" on the saved popup → player + timeline, mark start/end, multi-cut, preview-with-cuts-skipped, saves an `_edited` COPY (original kept) via our own reader→writer re-encode at RecordingConfig bitrates (NOT AVAssetExportSession — its presets double file size and break the WhatsApp-size promise). Edited copy becomes lastSavedURL so WhatsApp/backup/link flows target it. "find in recording" (on-device transcription, type a word or phrase and jump to it) is built into the editor.
- [x] Automated E2E tests: `bash autotest.sh` (repo root) — launches the installed app in scripted `-autotest <scenario>` mode (baseline / pause-resume / screen-stall / camera-stall / mic-stall with simulated device failures via hidden `simulate*StallAfterSeconds` keys, plus webcam-only / webcam-only-float), then mechanically verifies the saved file (ffprobe A/V durations), watchdog behaviour, the audio-speed diagnostics (dropMono=0, effHz≈audioHz), and — for the two webcam-only scenarios — that the middle of the picture is not black (ffmpeg brightness; needs the camera uncovered in a lit room). `mic-stall` accepts audio that ends where the mic was silenced, so it passes with "computer sound" on or off. Run after every build alongside `xcodebuild test`.
- [x] Amplitude analytics (`Models/Analytics.swift`) — feature-usage events only, no client data; live (API key set in `Analytics.apiKey`, EU data centre); auto-disabled during autotest runs.
- [x] Copy transcript (v1.9.5): "copy transcript" in the trim editor + saved banner — renders the on-device word-timestamped transcription as plain text ([m:ss] paragraph markers) onto the clipboard, for pasting a check-in into notes or an AI summariser. Same cache as find-in-recording.
- [x] "computer sound" toggle (v1.9.5): recorder-bar segItem — OFF records mic-only (no system-audio track created; `RecordingConfig.recordSystemAudio` → `capturesAudio` + writer input skipped), so a coach can talk over a client's loud gym video without the music reaching the check-in. Default ON, persisted.
- [x] Auto weekly transcripts (v1.9.5): opt-in ⚙ toggle — after each save, `VideoTranscriber.autoExport` transcribes on-device and appends a section to `WC <Monday> transcripts.txt` in the week's folder (deduped on filename, lock-serialised), mirroring the doc to the backup folder. Lets coaches point Claude/AI at a week of check-ins (the "Loom→AI" ask) with coach-owned storage.
- [x] Crash + error reporting via Sentry (build 83; `Models/Telemetry.swift` — see "Error Tracking (Sentry)"): crashes, app hangs, recording start / writer / save failures, interruptions and audio anomalies, as numbers and tokens only (no client data, no file names). Off without a DSN, honours the `shareDiagnostics` opt-out, sends nothing during autotest runs.
- [x] Clean-exit marker + launch scan (build 83; `Models/SessionMarker.swift`, `Models/RecordingsHealthScan.swift`): reports a previous session that crashed or was force-quit (with what the recorder was doing) and recordings that never finalised (empty / unfinished / truncated), so a lost check-in surfaces even when the coach never mentions it.
- [x] Release guards + debug symbols (build 83; `Scripts/release_common.sh`, `Scripts/upload_dsyms.sh`, `Scripts/set_sentry_dsn.sh`): the DMG scripts refuse a stale export or a build with no Sentry DSN, keep each build's dSYMs in `build/dsyms/<version>-<build>/` and upload them to Sentry so crash reports show function names and line numbers.
- [ ] Progress indicator during export compression

## Adding a New Feature
1. Add data to `Models/AppState.swift` or `Models/RecordingConfig.swift`.
2. Add logic to the appropriate folder (`Recording/`, `Export/`, etc.).
3. Wire into `UI/RecordingView.swift` or a new view.
4. Update this file's Feature Status section.
