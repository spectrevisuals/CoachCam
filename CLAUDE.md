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
Sentry is integrated for error reporting and crash monitoring. To set up:
1. **Create a Sentry project**: Go to [sentry.io](https://sentry.io), create an account/org, and create a new macOS/Swift project
2. **Copy your DSN**: From the Sentry project settings, copy your Data Source Name (DSN)
3. **Update the DSN**: In `CoachCapApp.swift`, replace `https://your-sentry-dsn@sentry.io/project-id` with your actual DSN
4. **Add the package**: In Xcode, go File → Add Packages, enter `https://github.com/getsentry/sentry-swift.git`, select version 8.0.0 or later
5. **Link to target**: When prompted, select the CoachCap target

Usage:
- `ErrorReporter.capture(_:context:level:)` — log errors
- `ErrorReporter.captureMessage(_:context:level:)` — log custom messages
- `ErrorReporter.addBreadcrumb(_:category:level:data:)` — track user actions leading up to errors

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
- [x] Webcam-only (talking-head) mode
- [x] Pause/resume (track cumulative paused duration, skip frames during pause)
- [x] Before/after photo stitcher (PhotoStitcher)
- [ ] Quick top-and-tail trim (next: AVAssetExportSession with time range)
- [ ] Progress indicator during export compression

## Adding a New Feature
1. Add data to `Models/AppState.swift` or `Models/RecordingConfig.swift`.
2. Add logic to the appropriate folder (`Recording/`, `Export/`, etc.).
3. Wire into `UI/RecordingView.swift` or a new view.
4. Update this file's Feature Status section.
