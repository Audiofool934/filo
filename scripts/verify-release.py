"""Check DMG/ZIP payloads; require notarization before publishing a release."""
import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("directory", nargs="?", type=Path, default=root / "dist")
parser.add_argument("--require-notarization", action="store_true",
                    help="require the official Developer ID, tickets, and Gatekeeper acceptance")
parser.add_argument("--tag", help="require a release tag matching the packaged version, e.g. v1.1.2")
args = parser.parse_args()
dist = args.directory.resolve()
expected = plistlib.loads((root / "Resources/Info.plist").read_bytes())
if args.tag and args.tag != "v" + expected["CFBundleShortVersionString"]:
    raise SystemExit("Release tag does not match Resources/Info.plist")

# Public signing identity, not a credential. Reject a valid signature by another developer.
release_team = "DAK5S3455A"


def run(*args):
    return subprocess.check_output(args)


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def verify_identity(path, executable=False):
    details = subprocess.check_output(
        ["codesign", "-d", "--verbose=4", str(path)], stderr=subprocess.STDOUT, text=True
    )
    require(re.search(r"^Authority=Developer ID Application:", details, re.M),
            "Public releases require Developer ID Application signing")
    require(f"TeamIdentifier={release_team}" in details.splitlines(), "Unexpected signing team")
    require(re.search(r"^Timestamp=", details, re.M), "Missing secure signing timestamp")
    if executable:
        require(re.search(r"^CodeDirectory .*flags=.*\(.*runtime.*\)", details, re.M),
                "Missing Hardened Runtime")


def inspect(app):
    run("codesign", "--verify", "--deep", "--strict", str(app))
    if args.require_notarization:
        verify_identity(app, executable=True)
        verify_identity(app / "Contents/MacOS/filo-lab", executable=True)
        run("xcrun", "stapler", "validate", str(app))
        run("spctl", "--assess", "--type", "execute", "--verbose=2", str(app))
    for name in ("filo", "filo-lab"):
        run("lipo", str(app / "Contents/MacOS" / name), "-verify_arch", "arm64", "x86_64")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion", "LSMinimumSystemVersion"):
        require(info[key] == expected[key], f"Packaged {key} differs from source")
    return {
        str(path.relative_to(app)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in app.rglob("*") if path.is_file()
    }


# Accept exactly our two assets; never follow paths supplied by a downloaded manifest.
checksums = {}
for line in (dist / "SHA256SUMS").read_text().splitlines():
    match = re.fullmatch(r"([0-9a-f]{64})  (filo-macos-universal\.(?:dmg|zip))", line)
    require(match is not None, "Invalid checksum manifest")
    digest, name = match.groups()
    require(name not in checksums, "Duplicate checksum entry")
    checksums[name] = digest
require(set(checksums) == {"filo-macos-universal.dmg", "filo-macos-universal.zip"},
        "Checksum manifest must cover both release assets")
for name, digest in checksums.items():
    require(hashlib.sha256((dist / name).read_bytes()).hexdigest() == digest,
            f"Checksum mismatch: {name}")

run("hdiutil", "verify", str(dist / "filo-macos-universal.dmg"))
if args.require_notarization:
    dmg = str(dist / "filo-macos-universal.dmg")
    run("codesign", "--verify", "--strict", dmg)
    verify_identity(dmg)
    run("xcrun", "stapler", "validate", dmg)
    run("spctl", "--assess", "--type", "open", "--context", "context:primary-signature",
        "--verbose=2", dmg)
with tempfile.TemporaryDirectory(prefix="filo-package-check-") as scratch:
    run("ditto", "-x", "-k", str(dist / "filo-macos-universal.zip"), scratch)
    zip_files = inspect(Path(scratch) / "filo.app")
    run(str(Path(scratch) / "filo.app/Contents/MacOS/filo-lab"), "help")
    # Use our own mountpoint, rather than reusing any image the user opened.
    mount = Path(scratch) / "mounted"
    mount.mkdir()
    run("hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount),
        str(dist / "filo-macos-universal.dmg"))
    try:
        require(os.readlink(mount / "Applications") == "/Applications", "Missing Applications shortcut")
        require((mount / ".DS_Store").is_file(), "Missing Finder layout")
        require((mount / ".background.tiff").is_file(), "Missing installation background")
        require(inspect(mount / "filo.app") == zip_files, "DMG and ZIP app contents differ")
        print("DMG and ZIP contain identical, signed, universal apps; installation shortcut and layout are present.")
        if args.require_notarization:
            print("Public release verified: official Developer ID, Hardened Runtime, timestamps, tickets, and Gatekeeper acceptance.")
    finally:
        subprocess.run(["hdiutil", "detach", str(mount)], check=True)
