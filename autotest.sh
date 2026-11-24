#!/bin/bash
# CoachCam automated end-to-end recording tests.
#
#   bash autotest.sh              # run all scenarios
#   bash autotest.sh baseline     # run one
#
# What it does: launches the INSTALLED app (/Applications/CoachCam.app) headlessly-scripted
# via its autotest driver (-autotest <scenario> launch flag), which records real video/audio,
# optionally injects a simulated device failure (screen/camera/mic feed silenced mid-recording
# so the watchdogs must stop + salvage), writes a JSON verdict and quits. This script then
# verifies the artefacts MECHANICALLY:
#   • the saved file exists, has video + audio, durations agree (no lost/corrupt recording)
#   • the finalize diagnostics show dropMono=0 and effHz[mic] ≈ audioHz[mic] (audio-speed guard)
#   • failure scenarios actually tripped the right watchdog (error-log phrase)
#   • webcam-only scenarios (with and without the float cam) show a picture, not black video
#
# Requirements: licensed Mac, permissions already granted, app installed at /Applications,
# a camera + mic present, and ~3 minutes where the machine isn't being used.
set -u
APP="/Applications/CoachCam.app/Contents/MacOS/CoachCam"
LOG="$HOME/Movies/CoachCap/CoachCam-error-log.txt"
OUTDIR="$(mktemp -d /tmp/coachcam-autotest.XXXX)"
FFPROBE="$(command -v ffprobe || echo /opt/homebrew/bin/ffprobe)"
[ -x "$APP" ] || { echo "✗ CoachCam not installed at /Applications"; exit 1; }
[ -x "$FFPROBE" ] || { echo "✗ ffprobe not found (brew install ffmpeg)"; exit 1; }
FFMPEG="$(command -v ffmpeg || echo /opt/homebrew/bin/ffmpeg)"

SCENARIOS=(${1:-baseline pause-resume screen-stall camera-stall mic-stall webcam-only webcam-only-float})
PASS=0; FAIL=0; RESULTS=""

probe() { "$FFPROBE" -v error -select_streams "$2" -show_entries stream=duration -of default=nk=1:nw=1 "$1" 2>/dev/null | head -1; }

# Brightness of the MIDDLE of the picture, measured on every frame (0-16 = black, 235 = white).
# Prints "<darkest frame> <average> <frame count>", or nothing on failure. The middle only: the
# coach's logo is burned into the top-right corner, and it would make an otherwise black
# recording look as if it had a picture. The darkest frame is what gets judged — an average
# would let a recording that is black for most of its length through.
# -nostdin: without it ffmpeg grabs the terminal and suspends a harness started in the background.
centre_brightness() {
  "$FFMPEG" -nostdin -v error -i "$1" -an \
      -vf "crop=iw/2:ih/2,signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=-" \
      -f null - 2>/dev/null \
    | awk -F= '/lavfi\.signalstats\.YAVG/ { v = $2 + 0; s += v; n++; if (n == 1 || v < m) m = v }
               END { if (n) printf "%.1f %.1f %d", m, s / n, n }'
}

run_scenario() {
  local sc="$1"; local verdict="$OUTDIR/$sc.json"; local extra=()
  case "$sc" in
    screen-stall) extra=(-simulateVideoStallAfterSeconds 4);;
    camera-stall) extra=(-simulateCameraStallAfterSeconds 4);;
    mic-stall)    extra=(-simulateMicStallAfterSeconds 4);;
  esac
  local log_start; log_start=$(wc -l < "$LOG" 2>/dev/null || echo 0)

  echo "── $sc ──"
  # Launch via `open` so the app runs under ITS OWN TCC identity (launchd parent). Exec'ing
  # the binary directly makes macOS attribute screen capture to the invoking shell's
  # responsible process (Terminal/IDE), which fails with "user declined TCCs" unless THAT
  # app has Screen Recording — so the harness only worked from some terminals.
  # ${extra[@]+...} guard: macOS's bash 3.2 treats an EMPTY array as unbound under set -u,
  # which silently killed the no-extra-args scenarios (baseline, pause-resume).
  open -n -a "/Applications/CoachCam.app" --args -autotest "$sc" -autotestOut "$verdict" ${extra[@]+"${extra[@]}"}
  sleep 3   # let it register with launchd before we start polling
  # Hard cap 3 min per scenario: the driver quits the app when the scenario ends.
  for _ in $(seq 1 180); do pgrep -x CoachCam >/dev/null || break; sleep 1; done
  pgrep -x CoachCam >/dev/null && { pkill -9 -x CoachCam; echo "  ✗ app hung — killed"; return 1; }

  [ -f "$verdict" ] || { echo "  ✗ no verdict written (driver never ran?)"; return 1; }
  local saved; saved=$(python3 -c "import json;print(json.load(open('$verdict')).get('savedPath') or '')")
  [ -n "$saved" ] && [ -f "$saved" ] || { echo "  ✗ no saved recording"; cat "$verdict"; return 1; }

  # File integrity: video + audio streams, durations agree.
  local vd ad; vd=$(probe "$saved" v:0); ad=$(probe "$saved" a:0)
  [ -n "$vd" ] || { echo "  ✗ no video track in $saved"; return 1; }
  [ -n "$ad" ] || { echo "  ✗ no audio track in $saved"; return 1; }
  # This run's lines in the error log, and its finalize diagnostics.
  local newlog; newlog=$(tail -n +"$((log_start + 1))" "$LOG" 2>/dev/null)
  local fin; fin=$(grep "finalize status" <<<"$newlog" | head -1)
  # screen-stall salvage KEEPS audio past the dead video on purpose (the coach's voice is the
  # valuable part), so audio>video there is correct behaviour, not the audio bug.
  if [ "$sc" = "screen-stall" ]; then
    python3 -c "import sys;v,a=float('$vd'),float('$ad');sys.exit(0 if a>=v-0.8 else 1)" \
      || { echo "  ✗ salvaged audio shorter than video (video=$vd audio=$ad)"; return 1; }
  elif [ "$sc" = "mic-stall" ] && grep -q "samples\[video=[0-9]* sys=0 " <<<"$fin"; then
    # A mic-only recording ("computer sound" off; the finalize line says sys=0). The mic is
    # silenced on purpose ~4 s in and the watchdog ends the recording ~3 s later, so the only
    # audio track rightly ends where the mic went quiet. With computer sound ON the strict
    # rule below applies: that track runs to the end of the video.
    python3 -c "import sys;v,a=float('$vd'),float('$ad');sys.exit(0 if 3.0<a<5.5 and a<v+0.8 else 1)" \
      || { echo "  ✗ mic-only mic-stall audio out of range (video=$vd audio=$ad, expected about 4 s)"; return 1; }
  else
    python3 -c "import sys;v,a=float('$vd'),float('$ad');sys.exit(0 if abs(v-a)<0.8 else 1)" \
      || { echo "  ✗ A/V duration mismatch (video=$vd audio=$ad) — the audio bug's signature"; return 1; }
  fi

  # Scenario-specific duration + watchdog expectations.
  case "$sc" in
    baseline)
      python3 -c "import sys;sys.exit(0 if 6<float('$vd')<12 else 1)" || { echo "  ✗ baseline duration off ($vd s)"; return 1; };;
    pause-resume)
      python3 -c "import sys;sys.exit(0 if 6.5<float('$vd')<10.5 else 1)" || { echo "  ✗ pause not skipped (duration $vd s, expected ~8)"; return 1; };;
    screen-stall)
      grep -q "stopped receiving screen" <<<"$newlog" || { echo "  ✗ screen watchdog never fired"; return 1; };;
    camera-stall)
      grep -q "camera stopped sending video" <<<"$newlog" || { echo "  ✗ camera watchdog never fired"; return 1; };;
    mic-stall)
      grep -q "microphone stopped sending audio" <<<"$newlog" || { echo "  ✗ mic watchdog never fired"; return 1; };;
    webcam-only|webcam-only-float)
      python3 -c "import sys;sys.exit(0 if 6<float('$vd')<12 else 1)" || { echo "  ✗ $sc duration off ($vd s)"; return 1; }
      grep -q "capture interrupted" <<<"$newlog" && { echo "  ✗ $sc was interrupted (see the error log)"; return 1; }
      [ -x "$FFMPEG" ] || { echo "  ✗ ffmpeg not found, cannot check the picture (brew install ffmpeg)"; return 1; }
      local darkest average frames
      read -r darkest average frames <<<"$(centre_brightness "$saved")"
      [ -n "${darkest:-}" ] || { echo "  ✗ could not measure the picture in $saved"; return 1; }
      # A frame with no camera in it is the compositor's flat black and measures exactly 16
      # (or 0). A real camera frame always measures higher, even while the exposure settles on
      # a dim scene (seen as low as 20), so the per-frame limit sits just above flat black and
      # the clip as a whole must also clear 20. This proves the recording is not black; that
      # it is the camera and not the desktop is covered by Tests/FrameCompositorTests.swift.
      python3 -c "import sys;sys.exit(0 if float('$darkest')>16.5 and float('$average')>=20 else 1)" \
        || { echo "  ✗ BLACK VIDEO: the camera is missing from at least part of the recording (darkest frame $darkest, average $average over $frames frames; a frame with no camera measures 16). If the lens is covered or the room is dark, fix that and re-run."; return 1; }
      echo "  picture brightness: darkest frame $darkest, average $average over $frames frames (a frame with no camera measures 16)";;
  esac
  grep -q "AUTOTEST FAIL" <<<"$newlog" && { echo "  ✗ driver reported failure"; return 1; }

  # Audio-speed regression guard from the finalize diagnostics of THIS run.
  if [ -n "$fin" ]; then
    grep -qE "dropMono=0" <<<"$fin" || { echo "  ✗ mic buffers dropped: $fin"; return 1; }
    # mic-stall mutilates the mic feed itself, so effHz over that track is meaningless there —
    # the scenario's real assertions (watchdog fired, partial saved) are checked above/below.
    [ "$sc" = "mic-stall" ] || \
    python3 - "$fin" <<'PY' || { echo "  ✗ effHz vs audioHz out of tolerance: $fin"; return 1; }
import re, sys
fin = sys.argv[1]
hz  = re.search(r"audioHz\[sys=\d+ mic=(\d+)\]", fin)
eff = re.search(r"effHz\[sys=\d+ mic=(\d+)\]", fin)
sys.exit(1) if not (hz and eff) else None
a, e = int(hz.group(1)), int(eff.group(1))
sys.exit(0 if a > 0 and abs(e - a) / a < 0.03 else 1)
PY
  fi
  echo "  ✓ pass  (file: $(basename "$saved"), video=${vd}s audio=${ad}s)"
  return 0
}

for sc in "${SCENARIOS[@]}"; do
  if run_scenario "$sc"; then PASS=$((PASS+1)); RESULTS+="  ✓ $sc\n"; else FAIL=$((FAIL+1)); RESULTS+="  ✗ $sc\n"; fi
  sleep 2
done

echo; echo "══════════════════════════"
printf "$RESULTS"
echo "══════════════════════════"
echo "passed $PASS / $((PASS+FAIL))  (verdicts in $OUTDIR)"
[ $FAIL -eq 0 ]
