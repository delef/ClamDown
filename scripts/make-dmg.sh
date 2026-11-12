#!/bin/bash
# Packs the notarized build/ClamDown.app into build/ClamDown.dmg: a drag-to-Applications window,
# signed with Developer ID, notarized and stapled.
# Run `scripts/build-app.sh release` and `scripts/notarize.sh` first. This uploads the disk image to Apple.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib/config.sh"
load_signing_config release || exit 1
load_signing_config notarize || exit 1

app="$ROOT/build/ClamDown.app"
dmg="$ROOT/build/ClamDown.dmg"
volume="ClamDown"

[ -d "$app" ] || { echo "error: $app does not exist. Run scripts/build-app.sh release first." >&2; exit 1; }
xcrun stapler validate "$app" >/dev/null 2>&1 \
  || { echo "error: $app has no stapled notarization ticket. Run scripts/notarize.sh first." >&2; exit 1; }
if [ -d "/Volumes/$volume" ]; then
  echo "error: /Volumes/$volume is already mounted. Eject it first." >&2
  exit 1
fi

work="$(mktemp -d)"
mount=""
cleanup() {
  [ -n "$mount" ] && hdiutil detach "$mount" -quiet -force 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

stage="$work/stage"
mkdir -p "$stage/.background"
ditto "$app" "$stage/ClamDown.app"
ln -s /Applications "$stage/Applications"
cp "$ROOT/Resources/dmg/background.tiff" "$stage/.background/background.tiff"

hdiutil create -quiet -volname "$volume" -srcfolder "$stage" -fs HFS+ -format UDRW -ov "$work/rw.dmg"
mount="$(hdiutil attach "$work/rw.dmg" -readwrite -noverify -noautoopen | sed -n 's|.*\(/Volumes/.*\)$|\1|p')"

# Window layout. The background (scripts/dmg-background.swift) is 720x460 points; the icon centers
# match the pads and the arrow drawn on it. The bounds add 28 points for the title bar.
# Finder may ask once for permission to be controlled by this terminal.
osascript <<EOF
tell application "Finder"
  tell disk "$volume"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 120, 920, 608}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 160
    set text size of viewOptions to 13
    set background picture of viewOptions to file ".background:background.tiff"
    set position of item "ClamDown.app" of container window to {190, 215}
    set position of item "Applications" of container window to {530, 215}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF

# Custom volume icon. Added after the Finder step, because Finder deletes .VolumeIcon.icns when it opens
# the window. SetFile ships with the Xcode command line tools; skip the icon when it is missing.
cp "$app/Contents/Resources/AppIcon.icns" "$mount/.VolumeIcon.icns"
if xcrun --find SetFile >/dev/null 2>&1; then
  xcrun SetFile -a C "$mount"
fi

rm -rf "$mount/.fseventsd"
sync
hdiutil detach "$mount" -quiet
mount=""

rm -f "$dmg"
hdiutil convert "$work/rw.dmg" -quiet -format UDZO -imagekey zlib-level=9 -o "$dmg"
codesign --force --timestamp -s "$SIGN_IDENTITY" "$dmg"

log="$work/notary.log"
xcrun notarytool submit "$dmg" --keychain-profile "$CLAMDOWN_NOTARY_PROFILE" --wait | tee "$log"
grep -q "status: Accepted" "$log" || { echo "error: notarization was not accepted" >&2; exit 1; }
xcrun stapler staple "$dmg"
spctl -a -t open --context context:primary-signature -vv "$dmg"
echo "notarized and stapled: $dmg"
