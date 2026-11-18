# Changelog

Release notes follow [Semantic Versioning](https://semver.org/) where applicable.

## [0.1.0] - 2026-11-18

First public development preview.

- macOS menu-bar host creates an extended display and streams H.264 to Android over USB/ADB reverse.
- Android receiver renders with MediaCodec and OpenGL; per-device settings, reconnect, and display placement are included.
- Simplified Chinese and English UI follows the host device's system language.
- Mac artifact targets Apple silicon; Android APK supports API 26+.

Known limitations: macOS uses private `CGVirtualDisplay`; Mac app is ad-hoc signed and not notarized; Android APK is development-signed; Windows, touch input, audio, and stable 90/120 fps are not supported.
