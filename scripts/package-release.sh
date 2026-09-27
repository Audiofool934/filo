#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build.sh --universal
# Keep the asset name stable so the latest-release download link survives updates.
archive="filo-macos-universal.zip"
ditto -c -k --sequesterRsrc --keepParent dist/filo.app "dist/$archive"
(cd dist && shasum -a 256 "$archive" > SHA256SUMS)
echo "Packaged dist/$archive"
