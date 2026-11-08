#!/bin/sh
# Rebuild the native macOS app icon from the original Playbasis P artwork.
# No generated/redrawn logo and no developer-machine donor path is required.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
ICON_SOURCE="$PROJECT_ROOT/packaging/Brand/playbasis-mark-2048.png"
ICON_OUTPUT="${1:-$PROJECT_ROOT/packaging/AppIcon.icns}"

TASK_ICON_WORK=$(mktemp -d "${TMPDIR:-/tmp}/playbasis-app-icon.XXXXXX")
trap 'rm -r "$TASK_ICON_WORK"' EXIT
trap 'exit 1' HUP INT TERM
ICONSET="$TASK_ICON_WORK/AppIcon.iconset"
mkdir "$ICONSET"

source_width=$(sips -g pixelWidth "$ICON_SOURCE" | awk '/pixelWidth:/ {print $2}')
source_height=$(sips -g pixelHeight "$ICON_SOURCE" | awk '/pixelHeight:/ {print $2}')
[ "$source_width" = 2048 ] && [ "$source_height" = 2048 ] || {
  echo "Expected the original 2048 x 2048 Playbasis P artwork." >&2
  exit 1
}

for points in 16 32 128 256 512; do
  retina=$((points * 2))
  sips -z "$points" "$points" "$ICON_SOURCE" --out "$ICONSET/icon_${points}x${points}.png" >/dev/null
  sips -z "$retina" "$retina" "$ICON_SOURCE" --out "$ICONSET/icon_${points}x${points}@2x.png" >/dev/null
done

iconutil --convert icns --output "$TASK_ICON_WORK/AppIcon.icns" "$ICONSET"
# A decode round-trip catches invalid containers and missing representations
# before the application is signed or a working install is replaced.
iconutil --convert iconset --output "$TASK_ICON_WORK/Verified.iconset" "$TASK_ICON_WORK/AppIcon.icns"
for representation in "$ICONSET"/*.png; do
  name=$(basename "$representation")
  [ -s "$TASK_ICON_WORK/Verified.iconset/$name" ] || {
    echo "Generated app icon is missing $name." >&2
    exit 1
  }
done

mkdir -p "$(dirname "$ICON_OUTPUT")"
mv "$TASK_ICON_WORK/AppIcon.icns" "$ICON_OUTPUT"
