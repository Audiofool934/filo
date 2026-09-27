#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# A caller-selected Xcode or Command Line Tools installation is respected.
configuration="${CONFIGURATION:-release}"
app_dir="${APP_DIR:-dist/filo.app}"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
if [[ "${1:-}" == "--universal" ]]; then
    for architecture in arm64 x86_64; do
        triple="$architecture-apple-macosx14.4"
        swift build -c "$configuration" --triple "$triple" --scratch-path ".build/$architecture"
    done
    for executable in filo filo-lab; do
        lipo -create ".build/arm64/arm64-apple-macosx/$configuration/$executable" ".build/x86_64/x86_64-apple-macosx/$configuration/$executable" -output "$app_dir/Contents/MacOS/$executable"
    done
elif [[ $# -eq 0 ]]; then
    swift build -c "$configuration"
    bin_dir="$(swift build -c "$configuration" --show-bin-path)"
    cp "$bin_dir/filo" "$app_dir/Contents/MacOS/filo"
    cp "$bin_dir/filo-lab" "$app_dir/Contents/MacOS/filo-lab"
else
    echo "Usage: bash scripts/build.sh [--universal]" >&2
    exit 1
fi
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
cp LICENSE "$app_dir/Contents/Resources/LICENSE"
cp -R Resources/Scenes "$app_dir/Contents/Resources/"
icon_work="$(mktemp -d "${TMPDIR:-/tmp}/filo-icons.XXXXXX")"
trap 'rm -rf "$icon_work"' EXIT
swift scripts/icon.swift "$icon_work/filo.iconset"
iconutil -c icns "$icon_work/filo.iconset" -o "$app_dir/Contents/Resources/filo.icns"
# Sign the nested laboratory executable before sealing the app bundle.
sign_options=(--force --sign "${SIGNING_IDENTITY:--}" --options runtime)
if [[ "${SIGNING_IDENTITY:--}" != "-" ]]; then sign_options+=(--timestamp); fi
codesign "${sign_options[@]}" "$app_dir/Contents/MacOS/filo-lab"
codesign "${sign_options[@]}" --entitlements Resources/filo.entitlements "$app_dir"
codesign --verify --deep --strict "$app_dir"
echo "Built $app_dir"
