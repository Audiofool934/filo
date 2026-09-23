# Frozen Spotify synthetic-reference inspection

This archive preserves the [exact helper source](inspect-spotify-reference.swift) used to inspect Spotify's playback of our original five-second synthetic reference.
Its SHA-256 is `88c72bf62dbc462c23e71b005e4c3b4a18afbc96739d78d4f7e04dbe1c364ab1`.
The [build record](BUILD.md) records the successful compile command, executable and linked-object hashes, toolchain, source hashes, and offline validation results.
The source is a frozen research snapshot, not application code, a supported player, or a runtime dependency.
No audio files or executable binaries are included.

The [fixture manifest](../../../validation/spotify-reference-fixtures.json) records the preparation and independent offline decoding of WAV, ALAC, and FLAC versions before any Spotify playback.
It is a byte-identical copy of the original manifest because that record contained no personal filesystem paths requiring replacement.
Its SHA-256 is `7893e4e24273ad0afa6f23a7134c53a4c743dca03be23b5a751dfec9fe058918`.
The manifest is fixture evidence, not a Spotify playback measurement.
Playback receipts independently identify the selected file, helper source and executable, capture bytes, comparison result, and route-restoration errors.

## What the helper measures

The helper resolves only the live `com.spotify.client` audio process and pins its process-specific tap to BlackHole at 44.1 kHz with `relay: false`.
It temporarily leases the default output route and source rate but never opens the physical DAC output.
Exclusive recovery precedes ordinary route recovery, and tap IO is stopped before route restoration on success, interruption, or failure.
It does not launch Spotify, select a song, operate playback controls, alter Spotify settings, or access subscription content.
The operator must play only the selected known synthetic local file once after `READY_ARMED`.

The reference is exactly 220,500 stereo frames at 44.1 kHz with 24-bit integer values.
Before device access, the helper loads the canonical WAV through `ReferencePCM`, checks every sample against `filo_test_sample`, then independently decodes the selected WAV, ALAC, or FLAC through AVAudioFile.
Every selected-file Float32 word must match the canonical reference, and its file hash must remain unchanged during decoding.
Capture comparison requires the complete first-to-last reference, zero mismatching Float32 words, no off-grid or non-finite samples, a silent prefix, and at least one second of silent suffix.
No gain fitting, rounding, resampling, or truncated-window pass is used.

The tap-only `AudioSession` metrics do not expose callback timestamp continuity, and the report explicitly marks that evidence unavailable.
The helper does not observe Spotify's decoder callbacks or a successful playback-completion delegate; complete reference coverage comes from the independent sample comparison.
AudioSession does not expose callback stop/destroy return statuses either, so route restoration alone is not proof of independently confirmed callback teardown.
The measurement does not establish subscription-master identity, physical DAC output, USB receiver delivery, or analog output.

## Prepare a fresh working layout

The frozen source cannot run in this directory as-is because it locates fixtures, source files, and output artifacts through the original repository `work/` layout.
Use a fresh checkout at the commit containing this archive and an empty task-owned `work/` directory rather than replacing an existing experiment.
The commands below are for Apple Silicon macOS with an installed macOS SDK and Swift toolchain.
Fixture preparation and offline validation do not play or capture audio.

```sh
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
xcrun swift build --configuration debug --product filo-lab -Xswiftc -warnings-as-errors
mkdir -p work/spotify-reference-fixtures
cp docs/research/experiments/spotify-reference/inspect-spotify-reference.swift work/inspect-spotify-reference.swift
.build/debug/filo-lab fixture --file work/filo-reference-44100-24.wav --hz 44100 --bits 24 --seconds 5
cp work/filo-reference-44100-24.wav "work/spotify-reference-fixtures/filo reference 44100 stereo 24bit WAV.wav"
/usr/bin/afconvert -f m4af -d alac work/filo-reference-44100-24.wav "work/spotify-reference-fixtures/filo reference 44100 stereo 24bit ALAC.m4a"
/usr/bin/afconvert -f flac -d flac work/filo-reference-44100-24.wav "work/spotify-reference-fixtures/filo reference 44100 stereo 24bit FLAC.flac"
```

The historical ALAC and WAV fixtures were byte-identical copies of the previously generated reference files, while FLAC was encoded from the original WAV with the format arguments shown above.
The reproduction recipe generates their equivalents from the same deterministic WAV instead of relying on untracked earlier files.
The canonical WAV hash is `43728e416e9d6c4b27f03a46aecc604e3353ee1d51dec8b0fcb2037a2f2cd58e`.
Container bytes may differ across encoder versions even when decoded samples are identical, so compare the manifest's hashes without assuming every regenerated ALAC or FLAC container must reproduce them.
The helper enforces original sample identity independently of the file hash and records the actual chosen file's hash in each new receipt.
The expected canonical interleaved Float32 sample-byte hash is `f8277734d6e03b38d497bc2397fed81e470cec581a9c564081d7a1db412ae428`.
Do not place ordinary songs or subscription recordings in this fixture directory.

## Compile and validate without playback

This is the exact compile command used for the archived helper, linking the existing FiloCore and FiloPCM objects.
The fresh-checkout package build above supplies those objects; that setup is not a claim that the historical cached objects were rebuilt immediately before every run.
Rebuilding with different paths, compilers, or SDKs need not reproduce the historical executable hash.

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools /usr/bin/swiftc -O -warnings-as-errors -target arm64-apple-macosx14.4 \
  -I .build/arm64-apple-macosx/debug/Modules \
  -I .build/arm64-apple-macosx/debug/FiloPCM.build \
  work/inspect-spotify-reference.swift \
  .build/arm64-apple-macosx/debug/FiloCore.build/*.swift.o \
  .build/arm64-apple-macosx/debug/FiloPCM.build/*.c.o \
  -o work/inspect-spotify-reference
work/inspect-spotify-reference --help
work/inspect-spotify-reference --known-synthetic-only --format wav --validate-only
work/inspect-spotify-reference --known-synthetic-only --format alac --validate-only
work/inspect-spotify-reference --known-synthetic-only --format flac --validate-only
```

`--help` reads no fixture or hardware state.
`--validate-only` performs bounded local decoding and returns before signal setup, journal recovery, HAL access, routing, or capture.
All three original offline validation runs passed with 441,000 compared Float32 words and zero mismatches.
An earlier helper revision failed when it attempted an extra read at EOF after successfully decoding every frame; the archived version uses exact valid-frame length, final frame position, sample count, and unchanged-file checks instead.
The [build record](BUILD.md) preserves that diagnosis and the earlier source hash without treating the failed preflight as a Spotify result.

## Explicit process-tap experiment

Playback is a separate operator-controlled experiment requiring BlackHole 2ch, the appropriate macOS recording permissions, and Spotify's local-file playback of the prepared fixture.
Ensure the playback queue contains no unrelated audio and that only the selected fixture plays once during the capture window.
The helper's original run procedure used a folder containing only these three synthetic files; it does not itself inspect the Spotify queue or enforce source selection through an application API.
Independently record the current device, format, and clock baseline, then verify restoration after the run.
Preserve any recovery journal and diagnose restoration errors before starting another measurement.

```sh
work/inspect-spotify-reference --known-synthetic-only --format flac --seconds 30 --label first
```

Wait for `READY_ARMED` before starting the selected fixture in Spotify.
Replace `flac` with `wav` or `alac` only when the corresponding local file is selected.
The helper waits at most 15 seconds for Spotify to expose a HAL process and captures for 10 to 60 whole seconds, defaulting to 45 seconds.
Its storage has a separate finite capacity of the requested duration plus two seconds and cannot grow indefinitely.
Synchronous CoreAudio calls are outside the enforceable control-loop time bound.
The example writes `work/spotify-flac-first-tap.f32` and `work/spotify-flac-first-tap.json`, refusing to overwrite either file.
Use a new label for another run rather than deleting or replacing a previous receipt.
Even a successful receipt establishes only the known local reference at the named software process-tap boundary, not Spotify streaming or end-to-end DAC delivery.

## Independent offline byte analysis

The frozen [Python analyzer](analyze-spotify-reference.py) manually parses the canonical signed24 WAV and compares complete Float32 words against the captured files.
Its SHA-256 is `cc5f1b58179a218fa5664e7879200c80efa0acdc36f76d2213d3289707b75fad`.
The [historical analysis](../../../validation/spotify-reference-analysis.json) includes all three captures and ten controls.
The analyzer requires Python 3 and NumPy and opens no audio device or player.
Run it from a working copy with the original WAV and capture names already present, choosing a new output path if preserving earlier records.

```sh
cp docs/research/experiments/spotify-reference/analyze-spotify-reference.py work/analyze-spotify-reference.py
python3 work/analyze-spotify-reference.py --output work/spotify-reference-analysis-reproduction.json
```

The default capture inputs are `spotify-flac-first-tap.f32`, `spotify-wav-first-tap.f32`, and `spotify-alac-first-tap.f32` beside the working script.
This invocation runs all ten controls, analyzes the captures, and writes the full report.
The optional `--self-test` flag prints only the control results and exits before capture analysis or report creation.
Repeated `--capture` arguments can instead select explicit local captures.
A newly recorded run can have different surrounding silence and a different whole-capture hash while its complete reference span still matches exactly.
