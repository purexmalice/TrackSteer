#!/bin/bash
# Builds TrackSteer.app. No Xcode project, no dependencies -- one Swift file
# compiled directly, wrapped in the minimal bundle macOS needs to grant
# Accessibility permission (which is only ever granted to a bundle, never to a
# bare executable).
set -e

APP="TrackSteer.app"
DEST="${1:-$HOME/Applications}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>TrackSteer</string>
  <key>CFBundleDisplayName</key><string>TrackSteer</string>
  <key>CFBundleExecutable</key><string>TrackSteer</string>
  <key>CFBundleIdentifier</key><string>com.jthorney.tracksteer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT licensed</string>
</dict>
PLIST
echo "</plist>" >> "$APP/Contents/Info.plist"

swiftc -O \
  -o "$APP/Contents/MacOS/TrackSteer" \
  -framework AppKit \
  -framework CoreGraphics \
  -F /System/Library/PrivateFrameworks \
  -framework MultitouchSupport \
  Sources/main.swift

# Ad-hoc signature. Accessibility is recorded against the signature, so an
# unsigned binary cannot hold the permission at all.
codesign --force --sign - "$APP"

echo "built $APP"
if [ -d "$DEST" ] || mkdir -p "$DEST"; then
  rm -rf "$DEST/TrackSteer.app"
  cp -R "$APP" "$DEST/TrackSteer.app"
  echo "installed to $DEST/TrackSteer.app"
fi
