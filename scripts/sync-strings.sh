#!/bin/bash
# Refreshes Resources/Localizable.xcstrings from the strings the Swift code uses. Every key is its English text.
# Usage: scripts/sync-strings.sh
# Builds the package with the compiler's string extraction on, then merges the .stringsdata files it writes into
# the catalog. Run it after changing UI text, and commit the catalog with the code.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

catalog="Resources/Localizable.xcstrings"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# The compiler writes a .stringsdata file only when it compiles a module. The output directory is new on every
# run, so SwiftPM compiles every module again instead of reusing an up-to-date build that writes nothing.
# The path goes through -Xfrontend: SwiftPM passes its own output directory to the driver, and the last one wins.
swift build --disable-keychain \
  -Xswiftc -emit-localized-strings \
  -Xswiftc -Xfrontend -Xswiftc -emit-localized-strings-path -Xswiftc -Xfrontend -Xswiftc "$tmp"

shopt -s nullglob
sources=("$tmp"/*.stringsdata)
[ ${#sources[@]} -gt 0 ] || { echo "error: the build wrote no .stringsdata files to $tmp" >&2; exit 1; }

if [ ! -f "$catalog" ]; then
  printf '%s\n' '{"sourceLanguage":"en","strings":{},"version":"1.0"}' > "$catalog"
fi
xcrun xcstringstool sync "$catalog" --stringsdata "${sources[@]}"
echo "synced $catalog from ${#sources[@]} .stringsdata file(s)"
