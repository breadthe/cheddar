#!/bin/sh
# Exports every app icon size from the master art into the asset catalog and writes its Contents.json.
# 16 and 32 px come from the simplified small-size art; everything else from the 1024 master.
# The placeholder PNGs are rendered from the SVGs next to them:
#   sips -s format png Design/AppIcon.svg --out Design/AppIcon-1024.png
#   sips -s format png Design/AppIcon-small.svg --out Design/AppIcon-small.png
set -eu

cd "$(dirname "$0")/.."
MASTER=Design/AppIcon-1024.png
SMALL=Design/AppIcon-small.png
OUT=Cheddar/Assets.xcassets/AppIcon.appiconset

for f in "$MASTER" "$SMALL"; do
  [ -f "$f" ] || { echo "missing $f" >&2; exit 1; }
done
mkdir -p "$OUT"

for size in 16 32; do
  sips -s format png -z "$size" "$size" "$SMALL" --out "$OUT/icon_$size.png" >/dev/null
done
for size in 64 128 256 512 1024; do
  sips -s format png -z "$size" "$size" "$MASTER" --out "$OUT/icon_$size.png" >/dev/null
done

entry() { # point-size scale pixel-size
  printf '    { "idiom": "mac", "size": "%sx%s", "scale": "%sx", "filename": "icon_%s.png" }' "$1" "$1" "$2" "$3"
}
{
  echo '{'
  echo '  "images": ['
  entry 16 1 16;    echo ','
  entry 16 2 32;    echo ','
  entry 32 1 32;    echo ','
  entry 32 2 64;    echo ','
  entry 128 1 128;  echo ','
  entry 128 2 256;  echo ','
  entry 256 1 256;  echo ','
  entry 256 2 512;  echo ','
  entry 512 1 512;  echo ','
  entry 512 2 1024; echo
  echo '  ],'
  echo '  "info": { "version": 1, "author": "xcode" }'
  echo '}'
} > "$OUT/Contents.json"

[ -f Cheddar/Assets.xcassets/Contents.json ] ||
  echo '{ "info": { "version": 1, "author": "xcode" } }' > Cheddar/Assets.xcassets/Contents.json

echo "Wrote $OUT"
