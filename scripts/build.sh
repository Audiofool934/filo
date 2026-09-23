#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# A caller-selected Xcode or Command Line Tools installation is respected.
configuration="${CONFIGURATION:-release}"
swift build -c "$configuration"
bin_dir="$(swift build -c "$configuration" --show-bin-path)"
app_dir="dist/filo.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/filo" "$app_dir/Contents/MacOS/filo"
cp "$bin_dir/filo-lab" "$app_dir/Contents/MacOS/filo-lab"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
cp LICENSE "$app_dir/Contents/Resources/LICENSE"
codesign --force --sign "${SIGNING_IDENTITY:--}" --options runtime --entitlements Resources/filo.entitlements "$app_dir"
codesign --verify --strict "$app_dir"
echo "Built $app_dir"
