#!/bin/bash
# Renders Resources/AppIcon.svg into Resources/AppIcon.icns. Uses Google Chrome to rasterize the SVG.
set -euo pipefail
cd "$(dirname "$0")/.."

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

printf '<html><body style="margin:0;background:transparent">%s</body></html>' "$(cat Resources/AppIcon.svg)" > "$TMP/icon.html"
"$CHROME" --headless=new --disable-gpu --hide-scrollbars --default-background-color=00000000 \
  --window-size=1024,1024 --screenshot="$TMP/icon.png" "file://$TMP/icon.html" >/dev/null 2>&1

mkdir "$TMP/AppIcon.iconset"
for size in 16 32 128 256 512; do
  sips -z $size $size "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icns"
