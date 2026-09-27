"""Check the actual DMG and ZIP payloads, without launching or installing the app."""
import hashlib
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent
dist = Path(sys.argv[1]).resolve() if len(sys.argv) == 2 else root / "dist"


def run(*args):
    return subprocess.check_output(args)


def inspect(app):
    run("codesign", "--verify", "--deep", "--strict", str(app))
    for name in ("filo", "filo-lab"):
        run("lipo", str(app / "Contents/MacOS" / name), "-verify_arch", "arm64", "x86_64")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    expected = plistlib.loads((root / "Resources/Info.plist").read_bytes())
    for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion", "LSMinimumSystemVersion"):
        assert info[key] == expected[key], key
    return {
        str(path.relative_to(app)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in app.rglob("*") if path.is_file()
    }


subprocess.run(["shasum", "-a", "256", "-c", "SHA256SUMS"], cwd=dist, check=True)
run("hdiutil", "verify", str(dist / "filo-macos-universal.dmg"))
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
        assert os.readlink(mount / "Applications") == "/Applications"
        assert (mount / ".DS_Store").is_file()
        assert (mount / ".background.tiff").is_file()
        assert inspect(mount / "filo.app") == zip_files, "DMG and ZIP app contents differ"
        print("DMG and ZIP contain identical, signed, universal apps; installation shortcut and layout are present.")
    finally:
        subprocess.run(["hdiutil", "detach", str(mount)], check=True)
