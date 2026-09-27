#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
notary_profile=""
if [[ $# -eq 2 && "$1" == "--notarize" && -n "$2" ]]; then
    notary_profile="$2"
elif [[ $# -ne 0 ]]; then
    echo 'Usage: bash scripts/package-release.sh [--notarize KEYCHAIN_PROFILE]' >&2
    exit 1
fi
identity="${SIGNING_IDENTITY:--}"
if [[ -n "$notary_profile" && "$identity" != "Developer ID Application:"* ]]; then
    echo 'Notarization requires SIGNING_IDENTITY set to the full Developer ID Application certificate name.' >&2
    exit 1
fi

# Build in isolation: packaging must never rewrite a running dist/filo.app.
mkdir -p dist
release_work="$(mktemp -d "${TMPDIR:-/tmp}/filo-release.XXXXXX")"
trap 'rm -rf "$release_work"' EXIT
app="$release_work/filo.app"
APP_DIR="$app" bash scripts/build.sh --universal
for executable in filo filo-lab; do
    lipo "$app/Contents/MacOS/$executable" -verify_arch arm64 x86_64
done

notarize() {
    local artifact="$1" receipt="$2"
    xcrun notarytool submit "$artifact" --keychain-profile "$notary_profile" --wait --output-format json > "$receipt"
    python3 - "$receipt" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
if result.get("status") != "Accepted":
    raise SystemExit(f"Notarization not accepted. Read {sys.argv[1]} and fetch the submission log with notarytool log.")
print("Notarization accepted:", result["id"])
PY
}

if [[ -n "$notary_profile" ]]; then
    # Staple the app before packaging so both ZIP and DMG contain its offline ticket.
    # Read the complete output before matching so grep cannot SIGPIPE codesign under pipefail.
    signature_details="$(codesign -d --verbose=4 "$app" 2>&1)"
    grep -q '^Authority=Developer ID Application:' <<< "$signature_details"
    mkdir -p dist/notarization
    ditto -c -k --sequesterRsrc --keepParent "$app" "$release_work/submit.zip"
    notarize "$release_work/submit.zip" dist/notarization/app.json
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    spctl --assess --type execute --verbose=2 "$app"
fi

# Only the packaging tools use Python dependencies; the app stays dependency-free.
if [[ ! -x .build/dmg-tools/bin/python ]]; then python3 -m venv .build/dmg-tools; fi
.build/dmg-tools/bin/python -m pip --disable-pip-version-check install --require-hashes -r scripts/dmg-requirements.txt
swift scripts/dmg-background.swift "$release_work"
archive="filo-macos-universal.zip"
image="filo-macos-universal.dmg"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")"
.build/dmg-tools/bin/python -m dmgbuild -s scripts/dmg-settings.py \
    -D app="$app" -D background="$release_work/background.png" "filo $version" "$release_work/$image"
if [[ "$identity" != "-" ]]; then
    codesign --force --sign "$identity" --timestamp "$release_work/$image"
fi
if [[ -n "$notary_profile" ]]; then
    notarize "$release_work/$image" dist/notarization/dmg.json
    xcrun stapler staple "$release_work/$image"
    xcrun stapler validate "$release_work/$image"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$release_work/$image"
fi
ditto -c -k --sequesterRsrc --keepParent "$app" "$release_work/$archive"
(cd "$release_work" && shasum -a 256 "$image" "$archive" > SHA256SUMS)
python3 scripts/verify-release.py "$release_work"
# Publish local artifacts only after every requested build and verification succeeds.
for artifact in "$image" "$archive" SHA256SUMS; do mv "$release_work/$artifact" "dist/$artifact"; done
echo "Packaged dist/$image and dist/$archive"
if [[ -z "$notary_profile" ]]; then
    echo 'These packages are NOT notarized. Use --notarize KEYCHAIN_PROFILE for a notarized release.'
fi
