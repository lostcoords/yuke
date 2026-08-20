#!/usr/bin/env sh
# Re-vendor the yuke SDK into docs-html/vendor/yuke.
#
# The docs chat imports the SDK from vendor/ (no build step on this side), so refresh it whenever
# yuke-ts-sdk changes. Copies the compiled dist only — relay/crypto, source maps, and .d.ts are
# dropped (the chat is Path A local-daemon and needs none of them).
#
#   docs-html/vendor-sdk.sh              # SDK at ../yuke-ts-sdk (sibling of the repo)
#   docs-html/vendor-sdk.sh /path/to/yuke-ts-sdk
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
sdk=${1:-"$repo/../yuke-ts-sdk"}
sdk=$(cd "$sdk" 2>/dev/null && pwd) || { echo "no SDK at ${1:-$repo/../yuke-ts-sdk}"; exit 1; }
dist="$sdk/dist"
dest="$here/vendor/yuke"

if [ ! -f "$dist/index.js" ]; then
  echo "no built dist at $dist — run 'npm run build' in $sdk first"
  exit 1
fi

rm -rf "$dest"
mkdir -p "$dest"
rsync -a --exclude='relay/' --exclude='*.map' --exclude='*.d.ts' "$dist/" "$dest/"

echo "vendored $(find "$dest" -name '*.js' | wc -l | tr -d ' ') files from $dist"
