#!/bin/sh
# Convert the approved PNG design into macOS resource formats. Original artwork
# stays intact; sips/iconutil only crop transparent padding and produce sizes.
set -eu
cd "$(dirname "$0")/.."
branding_source=assets/branding
branding_work=$(mktemp -d "${TMPDIR:-/tmp}/localeshift-icons.XXXXXX")
trap 'rm -rf "$branding_work"' EXIT
mkdir -p "$branding_work/AppIcon.iconset" Sources/LocaleShiftApp/Resources
for branding_points in 16 32 128 256 512; do
    /usr/bin/sips -z "$branding_points" "$branding_points" "$branding_source/localeshift-time-language-v7.png" --out "$branding_work/AppIcon.iconset/icon_${branding_points}x${branding_points}.png" >/dev/null
    branding_pixels=$((branding_points * 2))
    /usr/bin/sips -z "$branding_pixels" "$branding_pixels" "$branding_source/localeshift-time-language-v7.png" --out "$branding_work/AppIcon.iconset/icon_${branding_points}x${branding_points}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$branding_work/AppIcon.iconset" -o "$branding_source/AppIcon.icns"
# The generated menu glyph's opaque bounds are x268..1176, y104..982 in a
# 1448x1086 canvas. Keep a transparent margin around these bounds, then produce
# a 4x representation displayed by AppKit at 19x18 points.
/usr/bin/sips --cropToHeightWidth 920 960 --cropOffset 84 244 "$branding_source/localeshift-menubar-v7.png" --out "$branding_work/StatusIconTemplate.png" >/dev/null
/usr/bin/sips -z 72 76 "$branding_work/StatusIconTemplate.png" --out Sources/LocaleShiftApp/Resources/StatusIconTemplate.png >/dev/null
echo 'Prepared AppIcon.icns and StatusIconTemplate.png.'
