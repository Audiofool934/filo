#!/bin/bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: scripts/verify-finite-reference.sh --output NAME --receipt RESULT.json [--reference FIXTURE.wav]
       scripts/verify-finite-reference.sh --check

Optional hardware laboratory test, not normal music playback.
Requires BlackHole 2ch and a DAC supporting exclusive interleaved signed32 output.
Plays only filo's original quiet five-second 44.1 kHz / 24-bit synthetic fixture.
If --reference is omitted, generates that fixture in a temporary directory.
The explicit receipt destination is never overwritten.
--check compiles the harness and prints its help without accessing audio hardware.
USAGE
}

filo_caller_dir="$PWD"
filo_repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
filo_output=""
filo_receipt=""
filo_reference=""
filo_check=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --check) filo_check=true; shift ;;
        --output|--receipt|--reference)
            [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 2; }
            case "$1" in
                --output) [[ -z "$filo_output" ]] || exit 2; filo_output="$2" ;;
                --receipt) [[ -z "$filo_receipt" ]] || exit 2; filo_receipt="$2" ;;
                --reference) [[ -z "$filo_reference" ]] || exit 2; filo_reference="$2" ;;
            esac
            shift 2 ;;
        *) usage >&2; exit 2 ;;
    esac
done
if [[ "$filo_check" == true ]]; then
    [[ -z "$filo_output" && -z "$filo_receipt" && -z "$filo_reference" ]] || { usage >&2; exit 2; }
else
    [[ -n "$filo_output" && -n "$filo_receipt" ]] || { usage >&2; exit 2; }
    [[ "$filo_receipt" = /* ]] || filo_receipt="$filo_caller_dir/$filo_receipt"
    [[ ! -e "$filo_receipt" && ! -L "$filo_receipt" ]] || { echo "Receipt already exists: $filo_receipt" >&2; exit 2; }
    [[ -d "$(dirname "$filo_receipt")" && -w "$(dirname "$filo_receipt")" ]] || { echo "Receipt directory must exist and be writable." >&2; exit 2; }
    if [[ -n "$filo_reference" ]]; then
        [[ "$filo_reference" = /* ]] || filo_reference="$filo_caller_dir/$filo_reference"
        [[ -f "$filo_reference" ]] || { echo "Reference file does not exist." >&2; exit 2; }
    fi
fi

[[ "$(uname -s)" == Darwin ]] || { echo "This laboratory harness requires macOS." >&2; exit 2; }
filo_arch="$(uname -m)"
case "$filo_arch" in arm64|x86_64) ;; *) echo "Unsupported host architecture: $filo_arch" >&2; exit 2 ;; esac
filo_sdk="$(xcrun --sdk macosx --show-sdk-path)"
filo_target="$filo_arch-apple-macosx14.4"
filo_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/filo-finite-reference.XXXXXX")"
filo_helper_pid=""
cleanup() {
    if [[ -n "$filo_helper_pid" ]] && kill -0 "$filo_helper_pid" 2>/dev/null; then
        kill -TERM "$filo_helper_pid" 2>/dev/null || true
        wait "$filo_helper_pid" 2>/dev/null || true
    fi
    rm -rf "$filo_build_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

cd "$filo_repo_dir"
filo_build_args=(--package-path "$filo_repo_dir" --scratch-path "$filo_build_dir/swift" --configuration debug --triple "$filo_target" --product filo-lab)
xcrun swift build "${filo_build_args[@]}" -Xcc -Wall -Xcc -Wextra -Xcc -Werror -Xswiftc -warnings-as-errors >&2
filo_bin_dir="$(xcrun swift build "${filo_build_args[@]}" --show-bin-path)"
xcrun clang -std=c11 -Wall -Wextra -Werror -target "$filo_target" -isysroot "$filo_sdk" \
    -c scripts/lab/finite-reference.c -o "$filo_build_dir/finite-reference.o"
xcrun swiftc -warnings-as-errors -target "$filo_target" -sdk "$filo_sdk" \
    -I "$filo_bin_dir/Modules" -Xcc "-fmodule-map-file=$filo_bin_dir/FiloPCM.build/module.modulemap" \
    -I Sources/FiloPCM/include -import-objc-header scripts/lab/finite-reference.h \
    scripts/lab/finite-reference.swift "$filo_build_dir/finite-reference.o" \
    "$filo_bin_dir"/FiloCore.build/*.o "$filo_bin_dir"/FiloPCM.build/*.o \
    -o "$filo_build_dir/finite-reference"

if [[ "$filo_check" == true ]]; then
    "$filo_build_dir/finite-reference" --help
    exit 0
fi
if [[ -z "$filo_reference" ]]; then
    filo_reference="$filo_build_dir/filo-reference-44100-24.wav"
    "$filo_bin_dir/filo-lab" fixture --file "$filo_reference" --hz 44100 --bits 24 --seconds 5 >&2
fi
"$filo_build_dir/finite-reference" --reference "$filo_reference" --receipt "$filo_receipt" --output "$filo_output" &
filo_helper_pid=$!
wait "$filo_helper_pid"
filo_helper_pid=""
