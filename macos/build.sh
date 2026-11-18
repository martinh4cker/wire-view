#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="$PWD/.build/WireView.app"
mkdir -p "$app/Contents/MacOS"
mkdir -p "$app/Contents/Resources"
cp macos/Info.plist "$app/Contents/Info.plist"
cp -R macos/Resources/. "$app/Contents/Resources/"
xcrun swiftc -O -target arm64-apple-macos15.0 -import-objc-header macos/VirtualDisplay.h \
    macos/main.swift macos/Localization.swift macos/Sender.swift macos/AppController.swift macos/StreamSettings.swift macos/DeviceProfiles.swift \
    macos/DisplayLayout.swift macos/USBReconnect.swift -o "$app/Contents/MacOS/WireView"
codesign --force --sign - "$app"
echo "$app"
