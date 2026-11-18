#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="$PWD/.build/WireView.app"
mkdir -p "$app/Contents/MacOS"
mkdir -p "$app/Contents/Resources"
cp macos/Info.plist "$app/Contents/Info.plist"
cp -R macos/Resources/. "$app/Contents/Resources/"
iconset="$PWD/.build/WireView.iconset"
mkdir -p "$iconset"
while read -r size scale filename; do
    pixels=$((size * scale))
    sips --resampleHeightWidth "$pixels" "$pixels" assets/wireview-app-icon.png \
        --out "$iconset/$filename" >/dev/null
done <<'ICON_SIZES'
16 1 icon_16x16.png
16 2 icon_16x16@2x.png
32 1 icon_32x32.png
32 2 icon_32x32@2x.png
128 1 icon_128x128.png
128 2 icon_128x128@2x.png
256 1 icon_256x256.png
256 2 icon_256x256@2x.png
512 1 icon_512x512.png
512 2 icon_512x512@2x.png
ICON_SIZES
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
xcrun swiftc -O -target arm64-apple-macos15.0 -import-objc-header macos/VirtualDisplay.h \
    macos/main.swift macos/Localization.swift macos/Sender.swift macos/TouchInput.swift macos/AppController.swift macos/StreamSettings.swift macos/DeviceProfiles.swift \
    macos/DisplayLayout.swift macos/USBReconnect.swift -o "$app/Contents/MacOS/WireView"
codesign --force --sign - "$app"
echo "$app"
