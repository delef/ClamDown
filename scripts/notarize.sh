#!/bin/bash
# Sends build/ClamDown.app to Apple's notary service, staples the ticket and writes build/ClamDown.zip.
# Run `scripts/build-app.sh release` first. This uploads the app to Apple.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib/config.sh"
load_signing_config notarize || exit 1

app="$ROOT/build/ClamDown.app"
zip="$ROOT/build/ClamDown.zip"

[ -d "$app" ] || { echo "error: $app does not exist. Run scripts/build-app.sh release first." >&2; exit 1; }
details=$(codesign -dvv "$app" 2>&1)  # captured first: `grep -q` closing a pipe would trip `pipefail`
if ! grep -q "Authority=Developer ID Application" <<<"$details"; then
  echo "error: $app is not signed with a Developer ID Application identity. Run scripts/build-app.sh release." >&2
  exit 1
fi

rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"

log="$(mktemp)"
trap 'rm -f "$log"' EXIT
xcrun notarytool submit "$zip" --keychain-profile "$CLAMDOWN_NOTARY_PROFILE" --wait | tee "$log"
grep -q "status: Accepted" "$log" || { echo "error: notarization was not accepted" >&2; exit 1; }

xcrun stapler staple "$app"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
spctl -a -vv "$app"
echo "notarized and stapled: $zip"
