#!/bin/bash
# Checks that build/ClamDown.app is well-formed and signed so the helper can verify the app.
# Exits 0 only when every check passes; prints one line per failed check.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
app="$ROOT/build/ClamDown.app"
failed=0

fail() {
  echo "FAIL: $1" >&2
  failed=1
}

if [ ! -d "$app" ]; then
  echo "FAIL: $app does not exist. Run scripts/build-app.sh first." >&2
  exit 1
fi

info="$app/Contents/Info.plist"
helper="$app/Contents/MacOS/ClamDownHelper"

plutil -lint "$info" >/dev/null || fail "Info.plist is not a valid plist"
id=$(plutil -extract CFBundleIdentifier raw -o - "$info" 2>/dev/null) || { fail "Info.plist has no CFBundleIdentifier"; id=""; }

daemon="$app/Contents/Library/LaunchDaemons/$id.helper.plist"
if [ -f "$daemon" ]; then
  plutil -lint "$daemon" >/dev/null || fail "daemon plist is not a valid plist"
  program=$(plutil -extract BundleProgram raw -o - "$daemon" 2>/dev/null || true)
  [ -n "$program" ] && [ -f "$app/$program" ] || fail "daemon plist BundleProgram '$program' does not exist in the bundle"
  [ "$(plutil -extract Label raw -o - "$daemon" 2>/dev/null)" = "$id.helper" ] || fail "daemon plist Label is not $id.helper"
else
  fail "missing $daemon"
fi

[ -x "$helper" ] || fail "ClamDownHelper is missing or not executable"
[ -x "$app/Contents/MacOS/ClamDown" ] || fail "ClamDown is missing or not executable"
[ -f "$app/Contents/Resources/Assets.car" ] && [ -f "$app/Contents/Resources/AppIcon.icns" ] \
  || fail "app icon (Assets.car and AppIcon.icns) is missing from Contents/Resources"

codesign --verify --strict --deep "$app" 2>/dev/null || fail "codesign --verify failed for the app"

# Capture first: `grep -q` closing the pipe early would trip `pipefail`.
app_details=$(codesign -dv "$app" 2>&1)
helper_details=$(codesign -dv "$helper" 2>&1)
grep -qx "Identifier=$id.helper" <<<"$helper_details" || fail "helper signing identifier is not $id.helper"

app_team=$(sed -n 's/^TeamIdentifier=//p' <<<"$app_details")
helper_team=$(sed -n 's/^TeamIdentifier=//p' <<<"$helper_details")
if [ -z "$app_team" ] || [ "$app_team" = "not set" ] || [ "$app_team" != "$helper_team" ]; then
  fail "app and helper must be signed by the same Team ID (app: '${app_team:-none}', helper: '${helper_team:-none}')"
fi

[ "$failed" -eq 0 ] && echo "bundle ok: $id (team $app_team)"
exit "$failed"
