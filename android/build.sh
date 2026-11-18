#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
sdk=${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}
tools="$sdk/build-tools/35.0.0"
platform="$sdk/platforms/android-35/android.jar"
[[ -x "$tools/aapt2" && -r "$platform" ]] || { echo '需要 Android SDK platform 35 和 build-tools 35.0.0' >&2; exit 1; }
out="$PWD/.build/android"
mkdir -p "$out/classes" "$out/dex"
javac --release 8 -cp "$platform" -d "$out/classes" android/*.java
find "$out/classes" -name '*.class' -print | LC_ALL=C sort > "$out/classes.list"
"$tools/d8" --lib "$platform" --min-api 26 --output "$out/dex" "@$out/classes.list"
"$tools/aapt2" link -I "$platform" --manifest android/AndroidManifest.xml -o "$out/resources.apk"
cp "$out/resources.apk" "$out/unaligned.apk"
(cd "$out/dex" && zip -q "$out/unaligned.apk" classes.dex)
"$tools/zipalign" -f 4 "$out/unaligned.apk" "$out/aligned.apk"
if [[ ! -e "$out/debug.jks" ]]; then
    keytool -genkeypair -keystore "$out/debug.jks" -storepass android -keypass android \
        -alias test -dname 'CN=WireView Prototype' -keyalg RSA -validity 3650 >/dev/null 2>&1
fi
"$tools/apksigner" sign --ks "$out/debug.jks" --ks-pass pass:android \
    --out "$out/wire-view.apk" "$out/aligned.apk"
"$tools/apksigner" verify "$out/wire-view.apk"
echo "$out/wire-view.apk"
