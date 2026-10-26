#!/usr/bin/env bash
# Render the social card and the home-screen icon into public/ with headless Chrome.
# Run it after a change to card.html, icon.html, or the logo. It needs website/node_modules.
set -euo pipefail
cd "$(dirname "$0")"
chrome="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
render() {
  "${chrome}" --headless=new --disable-gpu --hide-scrollbars --allow-file-access-from-files \
    --force-device-scale-factor=1 --window-size="$2" --screenshot="$3" "file://${PWD}/$1" 2>/dev/null
}
render card.html 1200,630 ../public/og.png
render icon.html 180,180 ../public/apple-touch-icon.png
