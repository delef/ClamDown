#!/bin/bash
# Uploads website/ to the Cloudflare Pages project in wrangler.toml.
# Usage: scripts/deploy-site.sh [preview|production]
#   preview     (default) publishes to a preview URL and leaves the live site alone
#   production  publishes to the live site
# Needs `npx wrangler login` once, or CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID in the environment.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
target="${1:-preview}"
case "$target" in
  preview) branch="preview" ;;
  production) branch="main" ;;
  *) echo "usage: scripts/deploy-site.sh [preview|production]" >&2; exit 2 ;;
esac

cd "$ROOT"

# Browsers may keep assets for hours, so a new page could show old scripts, styles or images.
# Publish a copy whose index.html asks for each asset by a hash of its content.
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
ditto website "$out"
stamp() { # path relative to website/
  local hash
  hash="$(shasum -a 256 "website/$1" | cut -c1-10)"
  sed -i '' "s|\"$1\"|\"$1?v=$hash\"|g" "$out/index.html"
}
stamp styles.css
stamp main.js
while IFS= read -r asset; do stamp "${asset#website/}"; done < <(find website/assets -type f ! -name '.*')
grep -q 'styles.css?v=' "$out/index.html" && grep -q 'main.js?v=' "$out/index.html" \
  && grep -q 'screens/cooling-light.webp?v=' "$out/index.html" \
  || { echo "error: could not stamp asset versions into index.html" >&2; exit 1; }

npx --yes wrangler@4 pages deploy "$out" --branch "$branch" --commit-dirty=true
