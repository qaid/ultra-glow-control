#!/bin/bash
# Rasterizes design/appicon.svg into an .iconset and packs it into design/AppIcon.icns.
# Idempotent: safe to re-run any time appicon.svg changes.
# Uses rsvg-convert (librsvg); falls back to cairosvg if that's what's installed.
set -e
cd "$(dirname "$0")"

SVG="appicon.svg"
ICONSET="AppIcon.iconset"
OUT="AppIcon.icns"

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

render() { # $1=size $2=outfile
  if command -v rsvg-convert >/dev/null 2>&1; then
    rsvg-convert -w "$1" -h "$1" "$SVG" -o "$2"
  elif command -v cairosvg >/dev/null 2>&1; then
    cairosvg "$SVG" -o "$2" --output-width "$1" --output-height "$1"
  else
    echo "Need rsvg-convert (brew install librsvg) or cairosvg" >&2; exit 1
  fi
}

# name:size pairs per Apple's iconset naming convention
declare -a SIZES=(
  "icon_16x16:16" "icon_16x16@2x:32"
  "icon_32x32:32" "icon_32x32@2x:64"
  "icon_128x128:128" "icon_128x128@2x:256"
  "icon_256x256:256" "icon_256x256@2x:512"
  "icon_512x512:512" "icon_512x512@2x:1024"
)

for pair in "${SIZES[@]}"; do
  render "${pair##*:}" "$ICONSET/${pair%%:*}.png"
done

rm -f "$OUT"
iconutil -c icns "$ICONSET" -o "$OUT"
rm -rf "$ICONSET"

echo "Built: $(pwd)/$OUT"
