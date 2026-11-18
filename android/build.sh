#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
sdk=${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}
tools="$sdk/build-tools/35.0.0"
platform="$sdk/platforms/android-35/android.jar"
[[ -x "$tools/aapt2" && -r "$platform" ]] || { echo '需要 Android SDK platform 35 和 build-tools 35.0.0' >&2; exit 1; }
out="$PWD/.build/android"
mkdir -p "$out/classes" "$out/dex"
resources="$out/res"
for density in mdpi hdpi xhdpi xxhdpi xxxhdpi; do mkdir -p "$resources/mipmap-$density"; done
sips --resampleHeightWidth 48 48 assets/wireview-app-icon.png --out "$resources/mipmap-mdpi/wireview_icon.png" >/dev/null
sips --resampleHeightWidth 72 72 assets/wireview-app-icon.png --out "$resources/mipmap-hdpi/wireview_icon.png" >/dev/null
sips --resampleHeightWidth 96 96 assets/wireview-app-icon.png --out "$resources/mipmap-xhdpi/wireview_icon.png" >/dev/null
sips --resampleHeightWidth 144 144 assets/wireview-app-icon.png --out "$resources/mipmap-xxhdpi/wireview_icon.png" >/dev/null
sips --resampleHeightWidth 192 192 assets/wireview-app-icon.png --out "$resources/mipmap-xxxhdpi/wireview_icon.png" >/dev/null
javac --release 8 -cp "$platform" -d "$out/classes" android/*.java
find "$out/classes" -name '*.class' -print | LC_ALL=C sort > "$out/classes.list"
"$tools/d8" --lib "$platform" --min-api 26 --output "$out/dex" "@$out/classes.list"
"$tools/aapt2" compile --dir "$resources" -o "$out/resources.zip"
mkdir -p "$out/compiled-res"
unzip -oq "$out/resources.zip" -d "$out/compiled-res"
resource_flats=()
while IFS= read -r file; do resource_flats+=("$file"); done < <(find "$out/compiled-res" -type f -name '*.flat' -print)
[[ ${#resource_flats[@]} -gt 0 ]] || { echo 'Android 图标资源编译失败' >&2; exit 1; }
"$tools/aapt2" link -I "$platform" --manifest android/AndroidManifest.xml \
    "${resource_flats[@]}" -o "$out/resources.apk"
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
