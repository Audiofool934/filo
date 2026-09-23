# Frozen AVAudioPlayer reference experiments

These are byte-for-byte snapshots of the temporary laboratory sources used for the [AVAudioPlayer measurements](../../player-api-reference-observation.md), preserved so that the baseline, rate-enabled control, and exclusive-output experiment can be audited externally.
They are research artifacts, not application code, a supported player, or a new runtime dependency.
They cannot be run in this directory as-is because their fixture, child executable, source-hash, and output locations are relative to the original repository `work/` layout.
No source code was changed when making these copies.

## Source identity and receipts

The following hashes match the `sourceSHA256` entries in the published receipts exactly.
The baseline files have a `-baseline` suffix here for preservation, but ran under their unsuffixed names in `work/`, which explains the unsuffixed receipt keys.

| Frozen source | SHA-256 | Published receipt |
| --- | --- | --- |
| [av-reference-player-baseline.swift](av-reference-player-baseline.swift) | `35b54c70dfdc9950cd3e5a4cd2b650b9057a09084c86a65ea5599755fb427737` | [Neutral tap](../../../validation/avplayer-alac-tap.json), key `av-reference-player.swift` |
| [inspect-api-reference-baseline.swift](inspect-api-reference-baseline.swift) | `fdbb322894a5a4b5ff93baa8cf82693244f86e8e44b60d19491c0da8526fa106` | [Neutral tap](../../../validation/avplayer-alac-tap.json), key `inspect-api-reference.swift` |
| [av-reference-player.swift](av-reference-player.swift) | `4962c2f8dd1b8b4859580843e144896cc30d093697e0991eca395f0d18d210cc` | [Rate-enabled tap](../../../validation/avplayer-alac-rate-enabled-tap.json), key `av-reference-player.swift`; [exclusive output](../../../validation/avplayer-exclusive-reference.json), key `work/av-reference-player.swift` |
| [inspect-api-reference.swift](inspect-api-reference.swift) | `eb3c92fdeb8840ce47d4272e3df2c3f0d312ce6f7738ad4c60cc85b86bf37817` | [Rate-enabled tap](../../../validation/avplayer-alac-rate-enabled-tap.json), key `inspect-api-reference.swift` |
| [inspect-av-exclusive.swift](inspect-av-exclusive.swift) | `a1f45a6ea8beba60f263cc2c1cd1ebe2dea2bb1d4fe961baf61c06ef30d201f8` | [Exclusive output](../../../validation/avplayer-exclusive-reference.json), key `work/inspect-av-exclusive.swift` |

The exclusive-output receipt additionally records hashes of its two executables and the linked production objects.
Source identity does not imply that a rebuild with a different compiler, SDK, or build path will reproduce the historical executable hash.
The recorded object hashes describe the objects used in that run, not an independently reproducible-build guarantee.

The optional [analyze-api-reference.py](analyze-api-reference.py) snapshot has SHA-256 `37f8e4b8b01e8a2dc1ca93a89b03adfd09a0d0dcdc5dcb9e865accab304d3f56`.
It is the retained offline script that produced the [analysis record](../../../validation/player-api-reference-analysis.json), but that original record did not embed the script's own hash.
Its hash is therefore documented here without claiming an original receipt-to-script hash binding.
The analysis record binds its reference, raw captures, and completed capture sidecars by hash.
Those local raw synthetic captures are not bundled in this source archive, so the historical offline analysis cannot be recomputed from this directory alone.

## Exact baseline-to-control change

The [complete unified diff](baseline-to-rate-enabled.diff) includes every changed line in both helper pairs.
The source hashes differ because the second experiment added an optional command-line control instead of mutating the baseline file's hardcoded setting.

The child's initializer gained an `enableRate` argument and the assignment `reference.enableRate = enableRate` immediately before preparation.
Its command-line parser, usage text, duplicate-argument validation, and initializer call were updated to support `--enable-rate`.
Both players still first receive volume `1`, pan `0`, rate `1`, and `enableRate = false`; the new assignment overrides only the reference player's rate-processing flag.
The separate silent player remains unchanged.
The property-readback implementation and fixture validation are byte-identical between the child snapshots.

The tap parent gained parsing and forwarding of `--enable-rate`, an updated usage string, and a `-rate-enabled` suffix for its capture and receipt filenames.
Its capture, comparison, and cleanup code did not change.
Thus the intended audio configuration difference in the recorded pair is the reference player's `enableRate` value, which the ready readbacks confirm as `false` and `true` respectively.
The pair used different helper builds, not one identical binary with two flags; the archived source diff makes that limitation and its exact scope inspectable.
The later exclusive-output experiment used the second child snapshot without `--enable-rate`, and its receipt confirms the flag was `false`.

## Build and fixture setup

Use a fresh checkout at the commit containing these snapshots, with an empty task-owned `work/` directory, to avoid overwriting local experiment sources or binaries.
Run the following commands from the repository root on Apple Silicon macOS with an installed macOS SDK and Swift toolchain.
The historical runs used macOS 26.6.2, build 25G83, BlackHole 2ch, and WALKMAN.
The compile commands below preserve the actual build distinctions: the child and exclusive parent used `-O`, while both tap-parent versions did not.
Only the build preparation commands are a fresh-checkout setup rather than a claim that the historical cached objects were rebuilt immediately before every experiment.

```sh
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
xcrun swift build --configuration debug --product filo-lab -Xswiftc -warnings-as-errors
xcrun swift build --scratch-path .build/source-readback --configuration debug --product filo-lab -Xswiftc -warnings-as-errors
mkdir -p work/reference-server
```

Generate only the original quiet synthetic fixture, then convert that WAV to ALAC with the same `afconvert` format arguments used for the recorded file.
This step writes local files and does not play or capture audio.

```sh
.build/debug/filo-lab fixture --file work/filo-reference-44100-24.wav --hz 44100 --bits 24 --seconds 5
cp work/filo-reference-44100-24.wav work/reference-server/filo-reference-44100-24.wav
/usr/bin/afconvert -f m4af -d alac work/filo-reference-44100-24.wav work/reference-server/filo-reference-44100-24.m4a
shasum -a 256 work/filo-reference-44100-24.wav work/reference-server/filo-reference-44100-24.m4a
```

The historical WAV hash is `43728e416e9d6c4b27f03a46aecc604e3353ee1d51dec8b0fcb2037a2f2cd58e`, and the historical ALAC file hash is `add662b2c40a791ddd0e406ad638848b58254fc4c4a0220f78e36d4b84510022`.
An ALAC container produced by a different encoder version may have different file bytes even when the decoded samples agree.
Both playback helpers independently require exactly 220,500 stereo frames at 44.1 kHz and 24 bits, and compare every decoded sample with `filo_test_sample` before playback.
The child additionally hashes the immutable file bytes supplied to AVAudioPlayer, and the parent requires the same file hash in its ready event.
Do not substitute arbitrary music or subscription material for this fixture.

For the original baseline, copy the baseline snapshots to their historical working names.

```sh
cp docs/research/experiments/avplayer-reference/av-reference-player-baseline.swift work/av-reference-player.swift
cp docs/research/experiments/avplayer-reference/inspect-api-reference-baseline.swift work/inspect-api-reference.swift
```

Compile the child from the helper plus the actual `AudioHardware.swift` and `ReferencePCM.swift` source files; this helper does not import `FiloCore` as a module.

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools /usr/bin/swiftc -O -warnings-as-errors -target arm64-apple-macosx14.4 \
  -I .build/source-readback/arm64-apple-macosx/debug/FiloPCM.build \
  Sources/FiloCore/AudioHardware.swift Sources/FiloCore/ReferencePCM.swift \
  work/av-reference-player.swift \
  .build/source-readback/arm64-apple-macosx/debug/FiloPCM.build/Transport.c.o \
  -o work/av-reference-player
```

Compile the tap parent using the existing package objects and its original nonoptimized command.

```sh
xcrun swiftc -warnings-as-errors -target arm64-apple-macos14.4 \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -I .build/debug/Modules \
  -Xcc -fmodule-map-file=.build/debug/FiloPCM.build/module.modulemap \
  -I Sources/FiloPCM/include work/inspect-api-reference.swift \
  .build/debug/FiloCore.build/*.o .build/debug/FiloPCM.build/*.o \
  -o work/inspect-api-reference
work/av-reference-player --help
```

The child's `--help` exits without reading the fixture or touching audio devices.
The frozen tap parents do not implement a `--help` flag; an invocation without a valid mode only prints usage and exits with status `2` before fixture or hardware access.

## Playback reproduction

The following invocations are separate, explicit hardware experiments, not build checks.
They require the relevant macOS recording permissions and a quiet, isolated test session with no unrelated playback routed through the devices under test.
The parents recover their task journals before starting, temporarily route the child to BlackHole at 44.1 kHz, and restore the leased route after cleanup.
Inspect each receipt and independently compare device, format, and clock state before and after a run, as the original investigation did.
If restoration reports a failure, retain its recovery journal and diagnose that failure before another run.

Run the baseline once after compiling the baseline pair.

```sh
work/inspect-api-reference alac
```

This creates `work/avplayer-alac-tap.f32` and `work/avplayer-alac-tap.json`, and refuses to overwrite them.
For the control, copy the second snapshots to the same working names, then repeat the child and tap-parent compile commands above.

```sh
cp docs/research/experiments/avplayer-reference/av-reference-player.swift work/av-reference-player.swift
cp docs/research/experiments/avplayer-reference/inspect-api-reference.swift work/inspect-api-reference.swift
```

After that rebuild, run the rate-enabled control once.

```sh
work/inspect-api-reference alac --enable-rate
```

This creates the separate `work/avplayer-alac-rate-enabled-tap.f32` and `.json` files without replacing the baseline outputs.
Both tap experiments observe only that child's process tap on BlackHole, with `relay: false`; they do not open the physical DAC output.

For the complete decoding-to-output-callback experiment, retain the second child build and compile the separate exclusive parent using its actual optimized command.

```sh
cp docs/research/experiments/avplayer-reference/inspect-av-exclusive.swift work/inspect-av-exclusive.swift
DEVELOPER_DIR=/Library/Developer/CommandLineTools /usr/bin/swiftc -O -warnings-as-errors -target arm64-apple-macosx14.4 \
  -I .build/arm64-apple-macosx/debug/Modules \
  -I .build/arm64-apple-macosx/debug/FiloPCM.build \
  work/inspect-av-exclusive.swift \
  .build/arm64-apple-macosx/debug/FiloCore.build/*.swift.o \
  .build/arm64-apple-macosx/debug/FiloPCM.build/*.c.o \
  -o work/inspect-av-exclusive
work/inspect-av-exclusive --help
```

The exclusive parent's `--help` does not read the fixture or touch hardware.
Its actual run requires one device named `WALKMAN`, one BlackHole source matching the production predicate, and compatible exclusive interleaved signed32 formats.
It intentionally has no generic output-device or music-file argument.

```sh
work/inspect-av-exclusive
```

The exclusive parent invokes its child with `--mode alac`, without `--enable-rate`, and requires neutral property readbacks before sending one `GO`.
It captures the actual signed32 output callback in memory and writes only `work/avplayer-exclusive-reference.json`, which it refuses to overwrite.
It requires whole-reference raw-byte equality, continuous capture/output timestamps, successful delegate completion, surrounding silence, and clean restoration.
Source decoder/output callback timestamps are unavailable from AVAudioPlayer and are explicitly marked unobserved.
The result concerns the actual DAC software callback, not the USB receiver or analog output.
Its measurement control-loop deadline is 20 seconds with bounded child teardown; synchronous CoreAudio calls cannot be force-interrupted safely by that deadline.

## Optional offline analysis

Copy the analysis snapshot to `work/analyze-api-reference.py` and use a Python environment with NumPy and SciPy.
Its reference and default capture paths are relative to the script's location, so running the archived copy in place does not find the original working layout.
The script never opens an audio device and uses exact original values after one fixed alignment; diagnostic rounding is not an equality criterion.

```sh
cp docs/research/experiments/avplayer-reference/analyze-api-reference.py work/analyze-api-reference.py
python3 work/analyze-api-reference.py --self-test
```

The full analysis additionally expects completed `work/known-reference-tap.f32` and `.json` from the separate Music experiment, plus both AVAudioPlayer `.f32` captures and their original sidecars.
Without those files it reports the missing inputs instead of generating a completed comparison.
With all original inputs available, use a new output filename because the script opens its result with exclusive creation.

```sh
python3 work/analyze-api-reference.py --output work/api-reference-analysis-reproduction.json
```

This archive adds external source and diff auditability to the existing receipts.
It does not turn the recorded outcomes into a claim that every macOS version, device, playback API configuration, or streaming service is bit-perfect.
