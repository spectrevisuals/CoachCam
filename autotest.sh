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

SCENARIOS=(${1:-baseline pause-resume screen-stall camera-stall mic-stall})
PASS=0; FAIL=0; RESULTS=""

probe() { "$FFPROBE" -v error -select_streams "$2" -show_entries stream=duration -of default=nk=1:nw=1 "$1" 2>/dev/null | head -1; }

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
  # screen-stall salvage KEEPS audio past the dead video on purpose (the coach's voice is the
  # valuable part), so audio>video there is correct behaviour, not the audio bug.
  if [ "$sc" = "screen-stall" ]; then
    python3 -c "import sys;v,a=float('$vd'),float('$ad');sys.exit(0 if a>=v-0.8 else 1)" \
      || { echo "  ✗ salvaged audio shorter than video (video=$vd audio=$ad)"; return 1; }
  else
    python3 -c "import sys;v,a=float('$vd'),float('$ad');sys.exit(0 if abs(v-a)<0.8 else 1)" \
      || { echo "  ✗ A/V duration mismatch (video=$vd audio=$ad) — the audio bug's signature"; return 1; }
  fi

  # Scenario-specific duration + watchdog expectations.
  local newlog; newlog=$(tail -n +"$((log_start + 1))" "$LOG" 2>/dev/null)
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
  esac
  grep -q "AUTOTEST FAIL" <<<"$newlog" && { echo "  ✗ driver reported failure"; return 1; }

  # Audio-speed regression guard from the finalize diagnostics of THIS run.
  local fin; fin=$(grep "finalize status" <<<"$newlog" | head -1)
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
