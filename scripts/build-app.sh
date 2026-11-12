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
arch_flags=()
[ "$config" = release ] && arch_flags=(--arch arm64 --arch x86_64)
# One product per call: given several --product flags, swift build builds only the last one.
swift build -c "$config" ${arch_flags[@]+"${arch_flags[@]}"} --product ClamDown
swift build -c "$config" ${arch_flags[@]+"${arch_flags[@]}"} --product ClamDownHelper
bin="$(swift build -c "$config" ${arch_flags[@]+"${arch_flags[@]}"} --show-bin-path)"
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
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Library/LaunchDaemons"
cp "$bin/ClamDown" "$bin/ClamDownHelper" "$app/Contents/MacOS/"
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

# Inside-out: the helper first, with an explicit identifier the app pins in its XPC requirement.
codesign --force --options runtime "$timestamp" -i "$CLAMDOWN_BUNDLE_ID.helper" -s "$SIGN_IDENTITY" "$app/Contents/MacOS/ClamDownHelper"
codesign --force --options runtime "$timestamp" -s "$SIGN_IDENTITY" "$app"

echo "built $app ($config, $CLAMDOWN_BUNDLE_ID)"
