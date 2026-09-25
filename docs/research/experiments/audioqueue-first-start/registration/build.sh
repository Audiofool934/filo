#!/bin/bash
set -euo pipefail
filo_probe_dir="$(cd "$(dirname "$0")" && pwd)"
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
filo_probe_sdk="$(xcrun --sdk macosx --show-sdk-path)"
xcrun swiftc -warnings-as-errors -sdk "$filo_probe_sdk" -target arm64-apple-macosx14.4 \
    "$filo_probe_dir/main.swift" -o "$filo_probe_dir/audioqueue-registration"
