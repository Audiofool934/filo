#!/usr/bin/env python3
"""Prepare the pinned no-wait tap experiment without building or running audio."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import subprocess
import sys


BASE = "4e77ac5f65d98359fe8bec4c3c3cb118bae6e822"
SOURCE = "Sources/FiloCore/ExclusiveRelaySession.swift"
ORIGINAL_SHA256 = "8996bddd5f4a5282c149918503f4e71eb93f716968ab302fa3b4373e3734eb14"
EXPERIMENTAL_SHA256 = "7bcf5dbbc7e4ff56ca6195c89d851c08285b66b37354194e4757aff9e762b144"
BEFORE = b"kAudioAggregateDeviceTapAutoStartKey: true"
AFTER = b"kAudioAggregateDeviceTapAutoStartKey: false"


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def prepare(repository, output):
    # Do not inherit alternate repositories, replacement refs, or lazy-fetch behavior.
    environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    environment.update(GIT_NO_LAZY_FETCH="1", GIT_TERMINAL_PROMPT="0")

    def git(*arguments):
        result = subprocess.run(
            ["git", "--no-replace-objects", "-c", "protocol.allow=never", "-c", "core.fsmonitor=false",
             "-C", str(repository), *arguments],
            env=environment, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        return result.stdout

    if os.path.lexists(output):
        raise ValueError("Output directory already exists; nothing was changed.")
    if not output.parent.is_dir():
        raise ValueError("Output directory parent must already exist.")
    if git("rev-parse", "--verify", BASE + "^{commit}").decode().strip() != BASE:
        raise ValueError("Pinned commit could not be verified locally.")

    snapshot = {}
    for entry in git("ls-tree", "-r", "-z", "--full-tree", BASE, "--", "Package.swift", "Sources", "Tests").split(b"\0"):
        if not entry:
            continue
        metadata, encoded_path = entry.split(b"\t", 1)
        mode, kind, object_id = metadata.decode("ascii").split()
        path = PurePosixPath(encoded_path.decode("utf-8"))
        if (mode not in ("100644", "100755") or kind != "blob" or path.is_absolute()
                or ".." in path.parts or str(path).encode("utf-8") != encoded_path
                or not (str(path) == "Package.swift" or path.parts[0] in ("Sources", "Tests"))):
            raise ValueError("Pinned snapshot contains an unsupported file entry.")
        if str(path) in snapshot:
            raise ValueError("Pinned snapshot contains a duplicate file.")
        snapshot[str(path)] = (git("cat-file", "blob", object_id), int(mode, 8) & 0o777)
    if ("Package.swift" not in snapshot or SOURCE not in snapshot
            or not any(path.startswith("Tests/") for path in snapshot)):
        raise ValueError("Pinned snapshot lacks required package sources or tests.")

    original, mode = snapshot[SOURCE]
    if sha256(original) != ORIGINAL_SHA256 or original.count(BEFORE) != 1:
        raise ValueError("Pinned relay source differs from the measured original.")
    experimental = original.replace(BEFORE, AFTER, 1)
    if sha256(experimental) != EXPERIMENTAL_SHA256:
        raise ValueError("Experimental relay source differs from the measured substitution.")
    snapshot[SOURCE] = (experimental, mode)
    provenance = {
        "baseCommit": BASE,
        "scope": "Experimental scratch build only, production files unchanged.",
        "onlySourceChange": "kAudioAggregateDeviceTapAutoStartKey: true -> false",
        "reason": "Prearm capture before any first AudioQueueStart without a source silent renderer.",
        "originalSourceSHA256": ORIGINAL_SHA256,
        "experimentalSourceSHA256": EXPERIMENTAL_SHA256,
        "changedFiles": [SOURCE],
    }

    # mkdir is the exclusive creation gate, including existing or broken symlinks.
    output.mkdir(mode=0o700)
    for relative, (data, mode) in snapshot.items():
        target = output / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("xb") as handle:
            handle.write(data)
        target.chmod(mode)
    with (output / "provenance.json").open("x", encoding="utf-8") as handle:
        handle.write(json.dumps(provenance, indent=2) + "\n")
    return {"prepared": True, "trackedFiles": len(snapshot), **provenance}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    arguments = parser.parse_args()
    # Preserve the final path component so an existing symlink is refused.
    output = Path(os.path.abspath(arguments.output_dir.expanduser()))
    try:
        result = prepare(arguments.repository.expanduser(), output)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        detail = error.stderr.decode("utf-8", errors="replace").strip() if isinstance(error, subprocess.CalledProcessError) else str(error)
        print("prepare-scratch: " + detail, file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
