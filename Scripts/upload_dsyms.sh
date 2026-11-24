#!/bin/bash
# Upload debug symbols (dSYMs) to Sentry, so crash reports show function names and line
# numbers instead of raw addresses.
#
# Runs as the last build phase of the CoachCap target ("Upload dSYMs to Sentry"), on archive
# builds only. It can also be run by hand:
#
#   CONFIGURATION=Release DWARF_DSYM_FOLDER_PATH="<folder with .dSYM bundles>" \
#     bash Scripts/upload_dsyms.sh
#
# RULES — this script must never fail a build or touch signing:
#   * every path ends with exit 0;
#   * it prints "note:" lines only (never "warning:" or "error:", which Xcode would turn into
#     build issues) — sentry-cli's own output is re-labelled for the same reason;
#   * it does nothing unless the configuration is Release;
#   * it does nothing when SENTRY_SKIP_DSYM_UPLOAD is 1 / YES (an explicit off switch);
#   * it skips quietly when sentry-cli is not installed, when there is no upload token, or when
#     the Sentry organisation / project are not known;
#   * it never uploads source code (no --include-sources) and never prints the token.
#
# Where the settings come from (never from this repository):
#   token    SENTRY_AUTH_TOKEN, or  [auth] token=...      in the file  <home folder>/.sentryclirc
#   org      SENTRY_ORG,        or  [defaults] org=...    in the same file
#   project  SENTRY_PROJECT,    or  [defaults] project=... in the same file
# A value that still starts with PASTE_ (the template placeholder) counts as missing.

note() { echo "note: [sentry dSYM upload] $*"; }

if [ "${CONFIGURATION:-}" != "Release" ]; then
  note "skipped (configuration is '${CONFIGURATION:-unset}', uploads happen for Release only)"
  exit 0
fi

# Off switch for one build: an archive that must not touch the network. Pass it to xcodebuild
# as a build setting (xcodebuild archive ... SENTRY_SKIP_DSYM_UPLOAD=YES) or set it in the
# environment. make_test_dmg.sh / make_release_dmg.sh still upload the same symbols afterwards.
case "${SENTRY_SKIP_DSYM_UPLOAD:-}" in
  1|YES|yes|true|TRUE)
    note "skipped (SENTRY_SKIP_DSYM_UPLOAD is set; the DMG scripts upload these symbols after stapling)"
    exit 0
    ;;
esac

# Build phases get a minimal PATH that has no sentry-cli on it; Homebrew installs to one of
# these two folders. They are added AFTER the existing PATH, so a sentry-cli the caller already
# has on PATH is the one that is used.
PATH="${PATH:-/usr/bin:/bin}:/opt/homebrew/bin:/usr/local/bin"
export PATH

if ! command -v sentry-cli >/dev/null 2>&1; then
  note "skipped (sentry-cli is not installed; looked on PATH, in /opt/homebrew/bin and in /usr/local/bin)"
  exit 0
fi

CONFIG_FILE="${HOME:-}/.sentryclirc"

# Read one key from one [section] of an ini file. Prints nothing when it is not there.
ini_value() {
  [ -f "$1" ] || return 0
  awk -v want_section="$2" -v want_key="$3" '
    /^[[:space:]]*[;#]/ { next }
    /^[[:space:]]*\[/ {
      section = $0
      sub(/^[[:space:]]*\[/, "", section)
      sub(/\].*$/, "", section)
      next
    }
    section == want_section {
      split_at = index($0, "=")
      if (split_at == 0) next
      key = substr($0, 1, split_at - 1)
      value = substr($0, split_at + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if (key == want_key) { print value; exit }
    }
  ' "$1" 2>/dev/null
}

# A real value: not empty and not a template placeholder.
is_set() {
  case "${1:-}" in
    ""|PASTE_*) return 1 ;;
    *) return 0 ;;
  esac
}

HAVE_TOKEN=no
if is_set "${SENTRY_AUTH_TOKEN:-}"; then
  HAVE_TOKEN=yes
elif is_set "$(ini_value "$CONFIG_FILE" auth token)"; then
  HAVE_TOKEN=yes        # sentry-cli reads it from the file itself; it is never passed around here
fi
if [ "$HAVE_TOKEN" != "yes" ]; then
  note "skipped (no upload token: SENTRY_AUTH_TOKEN is not set and $CONFIG_FILE has no token yet)"
  exit 0
fi

ORG="${SENTRY_ORG:-}"
is_set "$ORG" || ORG="$(ini_value "$CONFIG_FILE" defaults org)"
PROJECT="${SENTRY_PROJECT:-}"
is_set "$PROJECT" || PROJECT="$(ini_value "$CONFIG_FILE" defaults project)"
if ! is_set "$ORG" || ! is_set "$PROJECT"; then
  note "skipped (Sentry organisation / project unknown: set SENTRY_ORG and SENTRY_PROJECT, or org= and project= under [defaults] in $CONFIG_FILE)"
  exit 0
fi

DSYM_DIR="${DWARF_DSYM_FOLDER_PATH:-}"
if [ -z "$DSYM_DIR" ] || [ ! -d "$DSYM_DIR" ]; then
  note "skipped (no dSYM folder at '${DSYM_DIR:-unset}')"
  exit 0
fi

# Only the .dSYM bundles are handed over. During an archive this folder also holds the app,
# its frameworks and object files, and none of those are to be uploaded.
BUNDLES=()
while IFS= read -r -d '' bundle; do
  BUNDLES+=("$bundle")
done < <(find "$DSYM_DIR" -maxdepth 1 -name '*.dSYM' -print0 2>/dev/null)
if [ "${#BUNDLES[@]}" -eq 0 ]; then
  note "skipped (no .dSYM bundles in '$DSYM_DIR')"
  exit 0
fi

note "uploading ${#BUNDLES[@]} debug symbol bundle(s) from $DSYM_DIR"
OUTPUT="$(sentry-cli debug-files upload --org "$ORG" --project "$PROJECT" "${BUNDLES[@]}" 2>&1)"
STATUS=$?

# Re-label sentry-cli's output so Xcode never reads a line as a build warning or error.
if [ -n "$OUTPUT" ]; then
  printf '%s\n' "$OUTPUT" \
    | sed -E -e 's/([Ee][Rr][Rr][Oo][Rr])[[:space:]]*:/\1 -/g' \
             -e 's/([Ww][Aa][Rr][Nn][Ii][Nn][Gg])[[:space:]]*:/\1 -/g' \
             -e 's/^/    sentry-cli | /'
fi

if [ "$STATUS" -eq 0 ]; then
  note "upload finished"
else
  note "upload did not succeed (sentry-cli exit code $STATUS) - the build is not affected; run make_release_dmg.sh or this script again to retry"
fi
exit 0
