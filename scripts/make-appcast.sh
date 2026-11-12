#!/bin/bash
# Writes build/appcast.xml for build/ClamDown.dmg: the Sparkle feed that tells installed copies about this release.
# Run it after scripts/make-dmg.sh, then attach both files to the GitHub release vX.Y.Z:
#   gh release create vX.Y.Z build/ClamDown.dmg build/appcast.xml
# Installed copies read https://github.com/delef/ClamDown/releases/latest/download/appcast.xml.
#
# Signs the disk image with the Sparkle EdDSA private key in CLAMDOWN_SPARKLE_KEY_FILE
# (Config/Signing.local.xcconfig, default ~/.config/clamdown/sparkle-ed25519.key), then checks the signature
# against the public key inside the built app, so a release can never ship with a key the app rejects.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib/config.sh"
cd "$ROOT"

app="build/ClamDown.app"
dmg="build/ClamDown.dmg"
out="build/appcast.xml"
sign_update=".build/artifacts/sparkle/Sparkle/bin/sign_update"
for file in "$app/Contents/Info.plist" "$dmg" "$sign_update"; do
  [ -e "$file" ] || { echo "error: $file is missing; run scripts/build-app.sh release and scripts/make-dmg.sh first" >&2; exit 1; }
done

key_file="$(xcconfig_value CLAMDOWN_SPARKLE_KEY_FILE 2>/dev/null || true)"
key_file="${key_file:-$HOME/.config/clamdown/sparkle-ed25519.key}"
key_file="${key_file/#\~/$HOME}"
[ -f "$key_file" ] || { echo "error: Sparkle private key $key_file is missing" >&2; exit 1; }

plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$app/Contents/Info.plist"; }
version="$(plist CFBundleShortVersionString)"
build="$(plist CFBundleVersion)"
minimum="$(plist LSMinimumSystemVersion)"
public_key="$(plist SUPublicEDKey)"

signature="$("$sign_update" -p --ed-key-file "$key_file" "$dmg")"
swift scripts/lib/ed25519-verify.swift "$public_key" "$dmg" "$signature" \
  || { echo "error: the DMG signature does not match SUPublicEDKey in the app; installed copies would refuse it" >&2; exit 1; }
length="$(stat -f %z "$dmg")"
pub_date="$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")"
tag="v$version"

cat > "$out" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>ClamDown</title>
    <link>https://clamdown.app</link>
    <item>
      <title>ClamDown $version</title>
      <pubDate>$pub_date</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$minimum</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/delef/ClamDown/releases/tag/$tag</sparkle:fullReleaseNotesLink>
      <enclosure url="https://github.com/delef/ClamDown/releases/download/$tag/ClamDown.dmg"
                 type="application/octet-stream" length="$length" sparkle:edSignature="$signature"/>
    </item>
  </channel>
</rss>
EOF
xmllint --noout "$out"
echo "wrote $out for ClamDown $version (build $build); attach it and $dmg to the $tag release"
