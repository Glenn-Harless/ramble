#!/bin/bash
# Builds Ramble.app, installs it to ~/Applications and starts it.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Ramble.app
TMP=build/tmp
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$TMP"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/app.html "$APP/Contents/Resources/"

# App icon, drawn by tools/make_icon.m at every size macOS wants.
clang -fobjc-arc -framework Cocoa tools/make_icon.m -o "$TMP/make_icon"
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  "$TMP/make_icon" "$ICONSET/icon_${s}x${s}.png" "$s"
  "$TMP/make_icon" "$ICONSET/icon_${s}x${s}@2x.png" "$((s * 2))"
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

clang -O2 -fobjc-arc -mmacosx-version-min=13.0 \
  -framework Cocoa -framework QuartzCore -framework WebKit -framework AVFoundation \
  -framework Carbon -framework CoreAudio -framework ServiceManagement -framework ScreenCaptureKit -framework CoreMedia \
  -o "$APP/Contents/MacOS/Ramble" Sources/main.m
# Sign with the self-signed "Ramble Signing" certificate when it exists, so macOS keeps
# Microphone / Accessibility / Screen Recording permissions across rebuilds. Without it,
# fall back to ad-hoc signing (permissions must be re-granted after every build).
IDENTITY="Ramble Signing"
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" --identifier local.ramble "$APP"
else
  echo "warning: no \"$IDENTITY\" certificate; signing ad-hoc (re-grant permissions after install)"
  codesign --force --sign - --identifier local.ramble "$APP"
fi

DEST="$HOME/Applications/Ramble.app"
pkill -x Ramble 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
touch "$DEST"  # nudge Finder and the Dock to pick up the new icon
open "$DEST"
echo "Installed and started $DEST"
