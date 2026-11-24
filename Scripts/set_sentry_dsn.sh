#!/bin/bash
# Store the Sentry DSN (the address crash and error reports are sent to) for local builds.
#
#   bash Scripts/set_sentry_dsn.sh "https://<key>@<host>/<project id>"
#
# Writes Config/Secrets.local.xcconfig next to Config/CoachCam.xcconfig. That file is ignored
# by git (this repository is public) and is picked up automatically by the next build — no
# need to run xcodegen again.
#
# Why a script: "//" starts a comment in an xcconfig file, so a DSN pasted as-is would be cut
# down to "https:". The value is written as  https:/$()/...  which Xcode expands back to
# https://...  when it fills in the SentryDSN key of the app's Info.plist.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Config/Secrets.local.xcconfig"

usage() {
  echo "Usage: bash \"$ROOT/Scripts/set_sentry_dsn.sh\" \"https://<key>@<host>/<project id>\""
  echo "       (copy the DSN from Sentry: Project Settings > Client Keys (DSN))"
}

if [ "$#" -ne 1 ]; then
  usage
  exit 2
fi

# Drop any stray spaces or line breaks from copy-and-paste.
DSN="$(printf '%s' "$1" | tr -d '[:space:]')"

if [ -z "$DSN" ]; then
  echo "✗ No DSN given."
  usage
  exit 2
fi

# Same shape the app checks at launch (TelemetryDSN in CoachCap/Models/TelemetryScrubber.swift).
SHAPE='^https://[A-Za-z0-9]+(:[A-Za-z0-9]+)?@[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._-]+)*/[0-9]+$'
if ! printf '%s\n' "$DSN" | grep -Eq "$SHAPE"; then
  echo "✗ That does not look like a Sentry DSN."
  echo "  Expected:  https://<key>@<host>/<project id>"
  echo "  Example:   https://0123456789abcdef0123456789abcdef@o123456.ingest.de.sentry.io/4501234567890123"
  echo "  Nothing was written."
  exit 1
fi

# "https://" -> "https:/$()/" so the xcconfig parser does not treat the rest as a comment.
ESCAPED="$(printf '%s' "$DSN" | sed 's#^https://#https:/$()/#')"
case "$ESCAPED" in
  *//*)
    echo "✗ The DSN contains \"//\" after the scheme, which an xcconfig file cannot hold."
    echo "  Nothing was written."
    exit 1
    ;;
esac

mkdir -p "$ROOT/Config" || { echo "✗ Could not create $ROOT/Config"; exit 1; }

{
  echo "// Written by Scripts/set_sentry_dsn.sh. Local only: ignored by git, never commit it."
  echo "// The DSN is written as https:/\$()/... because \"//\" starts a comment in an xcconfig"
  echo "// file; Xcode turns it back into https://... when it builds."
  echo "SENTRY_DSN = $ESCAPED"
} > "$OUT" || { echo "✗ Could not write $OUT"; exit 1; }
chmod 600 "$OUT" 2>/dev/null || true

# Show where it went without echoing the key itself.
MASKED="$(printf '%s' "$DSN" | sed -E 's#^https://[^@]+@#https://<key>@#')"
echo "✓ Saved the DSN ($MASKED) to:"
echo "    $OUT"
echo "  The next build puts it into the app's Info.plist as SentryDSN."
echo "  To remove it again, delete that file."
