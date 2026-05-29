#!/bin/bash
# Renders the app icon and builds Resources/AppIcon.icns. Run once (or after
# editing scripts/render-icon.swift); make-app.sh copies the result into the bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

xcrun swiftc -target arm64-apple-macos26.0 scripts/render-icon.swift -o /tmp/render-icon
/tmp/render-icon /tmp/icon-1024.png

ICONSET=/tmp/AppIcon.iconset
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    d=$((s * 2))
    sips -z "$s" "$s" /tmp/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png"     >/dev/null
    sips -z "$d" "$d" /tmp/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png"  >/dev/null
done

mkdir -p Resources
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icns"
