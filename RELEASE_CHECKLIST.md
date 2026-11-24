# CoachCam — Pre-Release Regression Checklist

Run this before **every** release. Each item is a bug we've already fixed at least once — the
point of this list is to make sure a new change hasn't silently undone an old fix. When we fix a
new bug, add a line here (and a unit test if it's pure logic — see `Tests/`).

Tick every box on a real build (the signed test build installed to `/Applications`), ideally with
an **external USB camera + mic** connected for the recording section, since that's where the
nastiest regressions live.

## Recording — reliability
- [ ] Record a **10+ minute** screen + face-cam clip → it saves a valid, playable file (opens in QuickTime, full duration).
- [ ] The saved clip **plays with sound in WhatsApp** (drag into WhatsApp or Premiere → exactly **one** audio track, voice + system audio both audible). *(WhatsApp plays only the first audio track — regressed twice.)*
- [ ] **Pull the USB mic** mid-recording → recording stops within ~3–5 s, shows "Your microphone disconnected…", and **saves the part filmed so far** (video + audio).
- [ ] **Pull the USB camera** mid-recording → stops, **no frozen face** burned into the tail, saves the partial.
- [ ] Force a writer failure (e.g. revoke Screen Recording permission mid-record) → stops **immediately** with a clear reason, not a silent 0-byte file, and never "films 20 min → get 10 s".
- [ ] **Video-stall watchdog:** arm `defaults write com.coachcam.app simulateVideoStallAfterSeconds -int 10`, relaunch CoachCam, record → at ~30 s it stops with "CoachCam stopped receiving screen video…" and saves the first ~10 s. **No Sentry event is expected:** a launch with a `simulate…StallAfterSeconds` key armed counts as a test run and sends nothing. Then `defaults delete …` to clear and relaunch, so reporting is back on. *(Catches the silent SCStream death — `samples[video=0/2]` — that lost a 32-min check-in; regressed once as a `video==0`-only check that missed `video=2`.)*
- [ ] A **normal** multi-minute recording does **not** trip the stall watchdog (frames flowing keep it quiet).
- [ ] Pause → resume → stop → audio and video stay in sync, no gap/overlap.
- [ ] Modes: **screen-only**, **webcam-only**, and **float-cam** each record and save correctly. **Webcam-only with the float cam open** shows the camera full-frame with square corners — not black video, and no black wedges in the corners. *(Build 84: the float cam blanked the camera in webcam-only; the full-frame camera was also drawn with the small bubble's rounded corners.)*

## Licensing / trial gate
- [ ] **Licensed** (trial or paid): full app — record, WhatsApp browser, before/after, export all work, **no watermark**, no recording cap.
- [ ] **Unlicensed** (deactivate to test): the whole app is replaced by the **"start your 28-day free trial"** wall — no tabs, no WhatsApp, no export reachable. Re-activating a key restores full access. *(Trial replaced the old 10-recordings/2-min/watermark freemium; the wall is the single gate so no feature can leak.)*

## Recording — behaviour / settings
- [ ] Auto-hide **defaults ON on the recorder screen** (window minimises on record) and **OFF on the before/after screen** (window stays visible). Each screen's toggle works independently and persists.
- [ ] On a save failure, `~/Movies/CoachCap/CoachCam-error-log.txt` gets a line with the real reason + free disk space + per-track sample counts.

## Before / after photos
- [ ] A check-in with HD+standard photo pairs shows **each photo once** (no duplicates). *(The "photos twice" dedup — regressed; see `Tests/PhotoDedupTests`.)*
- [ ] Search a client → pick them → **A / D and ← / → scrub photos immediately** (no click needed). *(Focus handoff — regressed; machine-dependent.)*
- [ ] While typing in the search box, **A/D type into it** (don't scrub).
- [ ] Client picker is ordered by **most recent WhatsApp chat**, and only lists clients who've sent photos.
- [ ] New WhatsApp photos appear after switching back to the app / pressing ↻, **without relaunch**.
- [ ] Running **AI match**, switching to WhatsApp and back → the match **stays** (photos don't vanish / reset).

## Devices
- [ ] Plug in a camera or mic while the app is open → it appears in the pickers **without relaunching**.

## v1.9.5 (build 84) — crash reporting (Sentry)
Do these on the notarised build installed in `/Applications`, in this order.
- [ ] `bash /Users/jake/Documents/ClaudeCode/CoachCap/make_test_dmg.sh` (or `make_release_dmg.sh`) printed **"✓ Sentry DSN is in the build"** and **"✓ Uploaded to Sentry."** *(No DSN = the build can never report anything. No upload = crash reports show raw addresses instead of function names.)*
- [ ] Quit CoachCam, then `open -a /Applications/CoachCam.app --args -sentryTestError YES` → within a minute Sentry shows **"sentry test error"** with release `CoachCam@1.9.5+84` (displayed as "1.9.5 (84)"), a user id of 8 characters, **no** `device_app_hash` under the event's App section, and a stack trace with app frames and line numbers (`closure in Telemetry.sendTestError (Telemetry.swift:…)`).
- [ ] Quit CoachCam, then `open -a /Applications/CoachCam.app --args -sentryTestCrash YES` (the app crashes on purpose after ~2 s), then **open CoachCam normally once** → the crash arrives in Sentry (titled "thunk for closure", level Fatal) and its stack trace shows **function names**, not raw addresses: top frame `+[SentrySDKInternal crash] (SentrySDKInternal.m:…)`, called from CoachCam's "thunk for closure". *(The optimiser folds `Telemetry.deliberateTestCrash` into that closure, so its own name does not appear.)* *(Open it normally: a launch through `autotest.sh`, or with a `simulate…StallAfterSeconds` key still set, throws the waiting crash report away.)*
- [ ] Quit normally (Cmd-Q) and reopen → **no** "previous session did not exit cleanly" event for that launch.
- [ ] Only after the three checks above: run `bash /Users/jake/Documents/ClaudeCode/CoachCap/autotest.sh`.

## v1.9.4 regression guards (2026-09-28)
- [ ] `xcodebuild test` — full unit suite green (98 tests: trim maths, transcript search, bitrate tiers, display sizing, stitch geometry, photo dedup, the telemetry privacy scrubber, the clean-exit marker and launch-scan rules).
- [ ] `bash autotest.sh` — all 7 E2E scenarios pass (baseline, pause-resume, screen/camera/mic stall salvage, webcam-only, webcam-only-float). The two webcam-only ones need the camera uncovered in a lit room.

## v1.9.3 regression guards (2026-09-03)
- [ ] **Audio complete on every mic**: record ~20s; log shows `dropMono=0` and `effHz[mic]` ≈ `audioHz[mic]` (±3%). *(The 1ns-rounding drop bug — guard must SPLICE, never drop micro-overlaps.)*
- [ ] **Toggling draw does NOT move/zoom the app window.** *(windowResizability(.contentSize) + fixedSize buttons — annotation UI must stay layout-neutral.)*
- [ ] **Drawing without the float cam shows the floating toolbar** (stop drawing / pen–line / eraser / stop & save), all clickable above the overlay.
- [ ] Recording defaults to **the monitor CoachCam's window is on**; dropdown pick sticks; never switches mid-recording.
- [ ] **send to whatsapp** always opens WhatsApp (chat deep-link best-effort), then reveals the file in Finder.
- [ ] An audio anomaly at finalize is reported to **Sentry** as a warning (numbers only, no filenames, no error text).

## Website / distribution
- [ ] `https://github.com/spectrevisuals/CoachCam/releases/latest/download/CoachCam.dmg` returns **200** (stable asset uploaded — the download-page button depends on it).
- [ ] Sparkle offers the new version as an update (verify in-app, on request).

## Notes
- Automated coverage of the pure-logic items lives in `Tests/` and runs with `xcodebuild test`.
- UI/hardware items above can't be unit-tested reliably — this manual pass is the safety net for them.
