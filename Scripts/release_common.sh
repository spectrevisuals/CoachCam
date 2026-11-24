#!/bin/bash
# Shared release steps for make_test_dmg.sh and make_release_dmg.sh (in the repo root).
#
# This file is SOURCED by those two scripts (". Scripts/release_common.sh"); running it on its
# own does nothing. It is written for the bash 3.2 that ships with macOS and for "set -e".
#
#   require_build <app> <build>
#       Stops the script unless the exported app has that build number. (The usual cause of a
#       mismatch is an export left over from the previous build.)
#
#   require_sentry_dsn <app>
#       Stops the script unless the exported app carries a well-formed Sentry DSN in its
#       Info.plist (key SentryDSN). Without one the build can never send a crash or error
#       report. To package such a build on purpose, run the script with ALLOW_NO_DSN=1.
#
#   save_and_upload_dsyms <app> <folder holding the archive's .dSYM bundles>
#       Run after stapling. Keeps a copy of the debug symbols in
#       build/dsyms/<version>-<build>/ (the next archive overwrites the archive's own copy),
#       then uploads them to Sentry through Scripts/upload_dsyms.sh, which skips quietly when
#       sentry-cli, the upload token or the organisation / project are missing.
#       It NEVER stops the script: by the time it runs, the DMG is already finished.
#       Call it as:   save_and_upload_dsyms "$APP" "$DSYMS" || true

RELEASE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || RELEASE_ROOT="$PWD"

# Same shape the app checks at launch (TelemetryDSN in CoachCap/Models/TelemetryScrubber.swift)
# and Scripts/set_sentry_dsn.sh checks before it saves a DSN.
SENTRY_DSN_SHAPE='^https://[A-Za-z0-9]+(:[A-Za-z0-9]+)?@[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._-]+)*/[0-9]+$'

# A path written out in full, for messages.
release_abs() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *)  printf '%s/%s' "$PWD" "$1" ;;
  esac
}

# One value from an Info.plist; prints nothing when the key or the file is not there.
release_plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true
}

# The debug ids (one per CPU architecture) of a binary or a .dSYM bundle, as one sorted line.
# Prints nothing when they cannot be read.
release_uuids() {
  [ -e "$1" ] || return 0
  dwarfdump --uuid "$1" 2>/dev/null \
    | awk '$1 == "UUID:" { print $2 " " $3 }' | sort | tr '\n' ';' || true
}

require_build() {
  local app="$1" expected="$2" plist actual
  plist="$(release_abs "$app")/Contents/Info.plist"
  actual="$(release_plist_value "$plist" CFBundleVersion)"
  if [ "$actual" = "$expected" ]; then
    return 0
  fi
  echo "✗ The exported app is build ${actual:-unknown}, expected $expected."
  echo "  Checked: $plist"
  echo "  That app is left over from an earlier export. Ask Claude to archive + export"
  echo "  build $expected again, then re-run this script:"
  echo "      bash \"$RELEASE_ROOT/$(basename "$0")\""
  exit 1
}

require_sentry_dsn() {
  local app="$1" plist dsn masked secrets
  plist="$(release_abs "$app")/Contents/Info.plist"
  dsn="$(release_plist_value "$plist" SentryDSN)"

  case "$dsn" in
    *$'\n'*) : ;;   # more than one line can never be a DSN; falls through to the failure below
    *)
      if [ "${#dsn}" -le 512 ] && printf '%s\n' "$dsn" | grep -Eq "$SENTRY_DSN_SHAPE"; then
        masked="$(printf '%s' "$dsn" | sed -E 's#^https://[^@]+@#https://<key>@#')" || masked="present"
        echo "✓ Sentry DSN is in the build ($masked)"
        return 0
      fi
      ;;
  esac

  if [ -z "$dsn" ]; then
    echo "✗ This build has no Sentry DSN, so it could never send a crash or error report."
  elif [ "$dsn" = "https:" ]; then
    echo "✗ This build's Sentry DSN was cut down to \"https:\"."
    echo "  (In an xcconfig file \"//\" starts a comment, so a DSN pasted in by hand loses everything after it.)"
  else
    echo "✗ This build's Sentry DSN is not a well-formed DSN (it should look like https://<key>@<host>/<project id>)."
  fi
  echo "  Checked: SentryDSN in $plist"

  if [ "${ALLOW_NO_DSN:-}" = "1" ]; then
    echo "  ALLOW_NO_DSN=1 is set, so it is being packaged anyway."
    echo "  This build will NOT report crashes or errors."
    return 0
  fi

  secrets="$RELEASE_ROOT/Config/Secrets.local.xcconfig"
  echo ""
  if [ -f "$secrets" ]; then
    echo "  A DSN has already been saved in:"
    echo "      $secrets"
    echo "  so the app was most likely exported before it was saved, or the saved value is wrong."
    echo "  To fix it:"
    echo "    1. If the saved DSN might be wrong, save it again (DSN between the second pair of quotes):"
    echo "         bash \"$RELEASE_ROOT/Scripts/set_sentry_dsn.sh\" \"PASTE_THE_DSN_HERE\""
    echo "    2. Ask Claude to archive + export the app again."
    echo "    3. Re-run this script:"
    echo "         bash \"$RELEASE_ROOT/$(basename "$0")\""
  else
    echo "  To fix it:"
    echo "    1. In Sentry, open Project Settings > Client Keys (DSN) and copy the DSN."
    echo "    2. Save it by running this in Terminal (DSN between the second pair of quotes):"
    echo "         bash \"$RELEASE_ROOT/Scripts/set_sentry_dsn.sh\" \"PASTE_THE_DSN_HERE\""
    echo "       That writes it to:"
    echo "         $secrets"
    echo "    3. Ask Claude to archive + export the app again."
    echo "    4. Re-run this script:"
    echo "         bash \"$RELEASE_ROOT/$(basename "$0")\""
  fi
  echo ""
  echo "  To package this build anyway, WITHOUT crash reporting:"
  echo "         ALLOW_NO_DSN=1 bash \"$RELEASE_ROOT/$(basename "$0")\""
  exit 1
}

save_and_upload_dsyms() {
  local app="$1" dsyms plist version build exe dsym_name app_ids dsym_ids base dest n saved
  local uploader output
  dsyms="$(release_abs "$2")"
  plist="$(release_abs "$app")/Contents/Info.plist"

  echo ""
  echo "→ Debug symbols (they let Sentry show function names and line numbers)…"

  if [ ! -d "$dsyms" ]; then
    echo "  !! No debug symbols found at: $dsyms"
    echo "     Nothing was saved or uploaded. The DMG itself is fine."
    return 0
  fi

  version="$(release_plist_value "$plist" CFBundleShortVersionString)"
  build="$(release_plist_value "$plist" CFBundleVersion)"
  exe="$(release_plist_value "$plist" CFBundleExecutable)"
  version="${version:-unknown}"
  build="${build:-unknown}"
  exe="${exe:-CoachCam}"
  dsym_name="$(basename "$app").dSYM"

  # Do these symbols belong to the app that went into the DMG? (An archive made after the
  # export, or an export left over from an older archive, would not match.)
  app_ids="$(release_uuids "$(release_abs "$app")/Contents/MacOS/$exe")"
  dsym_ids="$(release_uuids "$dsyms/$dsym_name")"
  if [ -n "$app_ids" ] && [ -n "$dsym_ids" ] && [ "$app_ids" != "$dsym_ids" ]; then
    echo "  !! The debug symbols in this folder do NOT belong to the app that was packaged:"
    echo "         $dsyms"
    echo "     (the archive and the export are from different builds). Nothing was saved or"
    echo "     uploaded, so crash reports from this DMG would show raw addresses. Tell Claude."
    return 0
  fi

  # Keep a copy. Never overwrite an earlier copy: a second, different binary with the same
  # build number gets its own folder (…_2, …_3).
  base="$RELEASE_ROOT/build/dsyms/$version-$build"
  dest="$base"
  n=1
  saved="no"
  while [ -e "$dest" ]; do
    if [ -n "$dsym_ids" ] && [ "$(release_uuids "$dest/$dsym_name")" = "$dsym_ids" ]; then
      saved="already"
      break
    fi
    n=$((n + 1))
    dest="${base}_$n"
  done
  if [ "$saved" = "already" ]; then
    echo "  ✓ A copy of these symbols is already saved in:"
    echo "         $dest"
  elif mkdir -p "$dest" && ditto "$dsyms" "$dest"; then
    echo "  ✓ Saved a copy to:"
    echo "         $dest"
  else
    echo "  !! Could not save a copy to: $dest"
    dest="$dsyms"
  fi

  # Upload, with the same quiet rules as the Xcode build phase (same script).
  uploader="$RELEASE_ROOT/Scripts/upload_dsyms.sh"
  if [ ! -f "$uploader" ]; then
    echo "  !! The upload script is missing, so the symbols were not uploaded to Sentry:"
    echo "         $uploader"
    return 0
  fi
  echo "  Uploading to Sentry (this can take a minute)…"
  output="$(CONFIGURATION=Release DWARF_DSYM_FOLDER_PATH="$dsyms" /bin/bash "$uploader" 2>&1)" || true
  if [ -n "$output" ]; then
    printf '%s\n' "$output" | sed 's/^/  /' || true
  fi
  # Scripts/upload_dsyms.sh prints "upload finished" when sentry-cli succeeded. If that wording
  # ever changes, the only effect is that the hint below is shown when it is not needed.
  case "$output" in
    *"upload finished"*)
      echo "  ✓ Uploaded to Sentry."
      ;;
    *)
      echo "  !! The symbols were NOT uploaded to Sentry (the lines above say why)."
      echo "     They are saved on this Mac. To upload them later, run:"
      echo "         CONFIGURATION=Release DWARF_DSYM_FOLDER_PATH=\"$dest\" bash \"$uploader\""
      ;;
  esac
  return 0
}
