#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build.sh --universal
version=$(/usr/libexec/PlistBuddy -c 'Print FiloReleaseLabel' dist/filo.app/Contents/Info.plist 2>/dev/null || /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' dist/filo.app/Contents/Info.plist)
archive="filo-$version-macos-universal.zip"
ditto -c -k --sequesterRsrc --keepParent dist/filo.app "dist/$archive"
(cd dist && shasum -a 256 "$archive" > SHA256SUMS)
echo "Packaged dist/$archive"
