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
npx --yes wrangler@4 pages deploy --branch "$branch" --commit-dirty=true
