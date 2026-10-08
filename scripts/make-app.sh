#!/bin/bash
# Builds TypeFlow as a proper, code-signed .app bundle.
#
# Why this exists: a bare SwiftPM binary has no Info.plist and no stable signed
# identity, so macOS cannot:
#   - grant Microphone access (needs NSMicrophoneUsageDescription + a signature)
#     → Apple dictation silently fails in the composer
#   - persist the Accessibility grant across rebuilds (TCC keys on bundle id)
#
# Wrapping the binary in TypeFlow.app fixes both.
#
# Usage:  ./scripts/make-app.sh [debug|release] [--no-install]
#
# By default this also installs the bundle to /Applications and relaunches it,
# so a rebuild always updates the app you actually run (the login item points at
# /Applications, NOT the repo-local TypeFlow.app — they drift otherwise). Pass
# --no-install to just build the local bundle without touching /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="release"
INSTALL=1
for arg in "$@"; do
    case "$arg" in
        debug|release) CONFIG="$arg" ;;
        --no-install)  INSTALL=0 ;;
        --install)     INSTALL=1 ;;
        *) echo "unknown argument: $arg (expected debug|release|--no-install)" >&2; exit 2 ;;
    esac
done
swift build -c "$CONFIG"
BIN=".build/$CONFIG/TypeFlow"

APP="TypeFlow.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TypeFlow"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>               <string>TypeFlow</string>
    <key>CFBundleDisplayName</key>        <string>TypeFlow</string>
    <key>CFBundleIdentifier</key>         <string>com.michaelv.typeflow</string>
    <key>CFBundleExecutable</key>         <string>TypeFlow</string>
    <key>CFBundleIconFile</key>           <string>AppIcon</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>0.1</string>
    <key>CFBundleVersion</key>            <string>1</string>
    <key>LSMinimumSystemVersion</key>     <string>26.0</string>
    <key>LSUIElement</key>                <true/>
    <key>NSPrincipalClass</key>           <string>NSApplication</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>TypeFlow uses the microphone for Apple dictation in the composer.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>TypeFlow uses speech recognition for Apple dictation in the composer.</string>
</dict>
</plist>
PLIST

# Sign with the stable self-signed identity if present, so Accessibility /
# Microphone grants persist across rebuilds. Fall back to ad-hoc (which resets
# the grants every build). Create the identity once with scripts/make-cert.sh.
IDENTITY="TypeFlow Self-Signed"
if security find-identity -p codesigning | grep -q "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" --identifier com.michaelv.typeflow "$APP"
    echo "Built $APP ($CONFIG), signed with '$IDENTITY'."
else
    codesign --force --sign - "$APP"
    echo "Built $APP ($CONFIG), AD-HOC signed (run scripts/make-cert.sh for a stable identity)."
fi

if [ "$INSTALL" -eq 1 ]; then
    # Install to /Applications and relaunch, so the app you run is always the one
    # you just built. ditto preserves the code signature (so the Accessibility /
    # Microphone grants — keyed on bundle id + signing identity — carry over).
    DEST="/Applications/TypeFlow.app"
    pkill -f 'TypeFlow.app/Contents/MacOS/TypeFlow' 2>/dev/null || true
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    open "$DEST"
    echo "Installed to $DEST and relaunched."
else
    echo "Skipped install (--no-install). Launch the local bundle with: open $APP"
fi
