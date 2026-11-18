#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun swiftc -O macos/Localization.swift macos/StreamSettings.swift macos/tests/StreamSettingsTests.swift -o .build/stream-settings-tests
.build/stream-settings-tests
xcrun swiftc -O macos/Localization.swift macos/StreamSettings.swift macos/DeviceProfiles.swift macos/USBReconnect.swift \
    macos/tests/DeviceProfilesTests.swift -o .build/device-profiles-tests
.build/device-profiles-tests
xcrun swiftc -O macos/Localization.swift macos/USBReconnect.swift macos/tests/USBReconnectTests.swift -o .build/usb-reconnect-tests
.build/usb-reconnect-tests
xcrun swiftc -O macos/Localization.swift macos/DisplayLayout.swift macos/tests/DisplayLayoutTests.swift -o .build/display-layout-tests
.build/display-layout-tests
xcrun swiftc -O -target arm64-apple-macos15.0 -import-objc-header macos/VirtualDisplay.h \
    macos/Sender.swift macos/AppController.swift macos/Localization.swift macos/StreamSettings.swift macos/DeviceProfiles.swift \
    macos/DisplayLayout.swift macos/USBReconnect.swift macos/tests/MenuSettingsTests.swift -o .build/menu-settings-tests
.build/menu-settings-tests "$@"
