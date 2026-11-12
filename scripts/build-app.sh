#!/bin/bash
# Builds build/ClamDown.app: the menu bar app plus the root helper daemon, signed inside-out.
# Usage: scripts/build-app.sh [debug|release]
#   debug   signs with CLAMDOWN_DEV_SIGN_IDENTITY (Apple Development), no secure timestamp
#   release signs with CLAMDOWN_SIGN_IDENTITY (Developer ID Application) and a secure timestamp
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
# Release builds are universal (Apple Silicon and Intel); debug builds stay native for speed.
# --disable-keychain: SwiftPM otherwise looks for github.com credentials in the keychain before it downloads
# the Sparkle binary, and a locked keychain then stalls the build on a dialog. Every dependency is public.
swift_flags=(-c "$config" --disable-keychain)
[ "$config" = release ] && swift_flags+=(--arch arm64 --arch x86_64)
# One product per call: given several --product flags, swift build builds only the last one.
swift build "${swift_flags[@]}" --product ClamDown
swift build "${swift_flags[@]}" --product ClamDownHelper
bin="$(swift build "${swift_flags[@]}" --show-bin-path)"
if [ "$config" = release ]; then
  # lipo -verify_arch takes one architecture per call here.
  for product in ClamDown ClamDownHelper; do
    for arch in arm64 x86_64; do
      lipo "$bin/$product" -verify_arch "$arch" \
        || { echo "error: $product has no $arch slice ($(lipo -archs "$bin/$product"))" >&2; exit 1; }
    done
  done
fi

app="$ROOT/build/ClamDown.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Library/LaunchDaemons" "$app/Contents/Frameworks"
cp "$bin/ClamDown" "$bin/ClamDownHelper" "$app/Contents/MacOS/"
# The linker also records rpaths into this checkout; the bundle needs only @executable_path/../Frameworks.
otool -l "$app/Contents/MacOS/ClamDown" | awk '/LC_RPATH/ { getline; getline; print $2 }' | while read -r rpath; do
  case "$rpath" in "$ROOT"/*) install_name_tool -delete_rpath "$rpath" "$app/Contents/MacOS/ClamDown" ;; esac
done

# Sparkle, for updates. ClamDown is not sandboxed, so Sparkle's XPC services are not needed; dropping them
# leaves less to sign and less code in the bundle.
sparkle="$app/Contents/Frameworks/Sparkle.framework"
ditto "$bin/Sparkle.framework" "$sparkle"
rm -rf "$sparkle/Versions/B/XPCServices" "$sparkle/XPCServices"
cp .build/artifacts/sparkle/Sparkle/LICENSE "$app/Contents/Resources/Sparkle-LICENSE.txt"
# Compiles the Icon Composer source into Assets.car (Liquid Glass) plus AppIcon.icns for older systems.
# Info.plist.template already names the icon, so actool's partial plist is discarded.
icon_tmp="$(mktemp -d)"
xcrun actool Resources/AppIcon.icon --compile "$app/Contents/Resources" --platform macosx \
  --minimum-deployment-target 13.0 --app-icon AppIcon --output-partial-info-plist "$icon_tmp/partial.plist" >/dev/null
rm -rf "$icon_tmp"
sed "s/@BUNDLE_ID@/$CLAMDOWN_BUNDLE_ID/g" Resources/Info.plist.template > "$app/Contents/Info.plist"
sed "s/@BUNDLE_ID@/$CLAMDOWN_BUNDLE_ID/g" Resources/helper-launchd.plist.template \
  > "$app/Contents/Library/LaunchDaemons/$CLAMDOWN_BUNDLE_ID.helper.plist"

timestamp="--timestamp"
[ "$config" = debug ] && timestamp="--timestamp=none"

# Inside-out: Sparkle's helpers, then Sparkle, then our helper, with an explicit identifier the app pins
# in its XPC requirement, then the app.
codesign --force --options runtime "$timestamp" -s "$SIGN_IDENTITY" "$sparkle/Versions/B/Autoupdate"
codesign --force --options runtime "$timestamp" -s "$SIGN_IDENTITY" "$sparkle/Versions/B/Updater.app"
codesign --force --options runtime "$timestamp" -s "$SIGN_IDENTITY" "$sparkle"
codesign --force --options runtime "$timestamp" -i "$CLAMDOWN_BUNDLE_ID.helper" -s "$SIGN_IDENTITY" "$app/Contents/MacOS/ClamDownHelper"
codesign --force --options runtime "$timestamp" -s "$SIGN_IDENTITY" "$app"

echo "built $app ($config, $CLAMDOWN_BUNDLE_ID)"
