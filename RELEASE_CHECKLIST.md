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
- [ ] **Video-stall watchdog:** arm `defaults write com.coachcam.app simulateVideoStallAfterSeconds -int 10`, record → at ~30 s it stops with "CoachCam stopped receiving screen video…", saves the first ~10 s, and (if a webhook is set) posts a 🟠 alert. Then `defaults delete …` to clear. *(Catches the silent SCStream death — `samples[video=0/2]` — that lost a 32-min check-in; regressed once as a `video==0`-only check that missed `video=2`.)*
- [ ] A **normal** multi-minute recording does **not** trip the stall watchdog (frames flowing keep it quiet).
- [ ] Pause → resume → stop → audio and video stay in sync, no gap/overlap.
- [ ] Modes: **screen-only**, **webcam-only**, and **float-cam** each record and save correctly.

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

## v1.9.3 regression guards (2026-09-03)
- [ ] **Audio complete on every mic**: record ~20s; log shows `dropMono=0` and `effHz[mic]` ≈ `audioHz[mic]` (±3%). *(The 1ns-rounding drop bug — guard must SPLICE, never drop micro-overlaps.)*
- [ ] **Toggling draw does NOT move/zoom the app window.** *(windowResizability(.contentSize) + fixedSize buttons — annotation UI must stay layout-neutral.)*
- [ ] **Drawing without the float cam shows the floating toolbar** (stop drawing / pen–line / eraser / stop & save), all clickable above the overlay.
- [ ] Recording defaults to **the monitor CoachCam's window is on**; dropdown pick sticks; never switches mid-recording.
- [ ] **send to whatsapp** always opens WhatsApp (chat deep-link best-effort), then reveals the file in Finder.
- [ ] An audio anomaly at finalize pings **Discord** (numbers only, no filenames).

## Website / distribution
- [ ] `https://github.com/spectrevisuals/CoachCam/releases/latest/download/CoachCam.dmg` returns **200** (stable asset uploaded — the download-page button depends on it).
- [ ] Sparkle offers the new version as an update (verify in-app, on request).

## Notes
- Automated coverage of the pure-logic items lives in `Tests/` and runs with `xcodebuild test`.
- UI/hardware items above can't be unit-tested reliably — this manual pass is the safety net for them.
