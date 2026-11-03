#!/bin/bash
# Builds build/Wakeup.app: the menu bar app plus the root helper daemon, signed inside-out.
# Usage: scripts/build-app.sh [debug|release]
#   debug   signs with WAKEUP_DEV_SIGN_IDENTITY (Apple Development), no secure timestamp
#   release signs with WAKEUP_SIGN_IDENTITY (Developer ID Application) and a secure timestamp
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib/config.sh"

config="${1:-debug}"
case "$config" in
  debug|release) ;;
  *) echo "usage: scripts/build-app.sh [debug|release]" >&2; exit 2 ;;
esac
load_signing_config "$config" || exit 1

cd "$ROOT"
swift build -c "$config" --product Wakeup --product WakeupHelper
bin="$(swift build -c "$config" --show-bin-path)"

app="$ROOT/build/Wakeup.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Library/LaunchDaemons"
cp "$bin/Wakeup" "$bin/WakeupHelper" "$app/Contents/MacOS/"
sed "s/@BUNDLE_ID@/$WAKEUP_BUNDLE_ID/g" Resources/Info.plist.template > "$app/Contents/Info.plist"
sed "s/@BUNDLE_ID@/$WAKEUP_BUNDLE_ID/g" Resources/helper-launchd.plist.template \
  > "$app/Contents/Library/LaunchDaemons/$WAKEUP_BUNDLE_ID.helper.plist"

timestamp="--timestamp"
[ "$config" = debug ] && timestamp="--timestamp=none"

# Inside-out: the helper first, with an explicit identifier the app pins in its XPC requirement.
codesign --force --options runtime "$timestamp" -i "$WAKEUP_BUNDLE_ID.helper" -s "$SIGN_IDENTITY" "$app/Contents/MacOS/WakeupHelper"
codesign --force --options runtime "$timestamp" -s "$SIGN_IDENTITY" "$app"

echo "built $app ($config, $WAKEUP_BUNDLE_ID)"
