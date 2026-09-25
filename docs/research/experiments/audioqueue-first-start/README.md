# AudioQueue first-start reproduction

The archived helpers compare the public AudioQueue default volume with one explicit unity assignment before its first start.
The [protocol and receipts](../../../validation/audioqueue-first-start/) record the measured pair and restoration evidence.
The [public API contracts](../../audioqueue-control-contracts.md) explain registration, parameter readbacks, reusable buffers, and tap startup behavior.

The scratch core is pinned to `4e77ac5f65d98359fe8bec4c3c3cb118bae6e822`, with exactly one substitution: `kAudioAggregateDeviceTapAutoStartKey: true` becomes `false`.
This permits capture to start before the child receives `GO`; it differs from production's tap setting.
The child queues the unchanged nonzero opening of the reference, followed by ten seconds of zeros, with no queued source prefix, `AudioQueuePrime`, earlier `AudioQueueStart`, or separate silent renderer.
The aggregate can still supply silent capture frames before `GO`, so an unstarted source does not imply that the relay itself had no silent preroll.
Exact full-reference callback bytes demonstrate this software boundary, not delivery to the Sony USB receiver or the cause of Spotify's onset transformation.

## Prepare and build without audio

Run from an Apple Silicon repository checkout containing the pinned commit, with Command Line Tools and Python 3 installed.
Use new `work/audioqueue-first-start-build`, `work/audioqueue-first-start`, `work/audioqueue-control`, and `work/reference-server` directories.
Keep `work/run-audioqueue-first-start.py` absent before copying the watchdog.
The preparation script reads only pinned Git blobs, blocks network protocols and lazy fetching, refuses an existing output path, verifies both relay-source hashes, and writes the measured provenance fields.
It does not build, invoke audio APIs, or change the repository checkout.

```sh
mkdir -p work
python3 docs/research/experiments/audioqueue-first-start/prepare-scratch.py \
  --repository "$PWD" --output-dir work/audioqueue-first-start-build
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
xcrun swift build --package-path work/audioqueue-first-start-build \
  --configuration debug --product filo-lab \
  -Xswiftc -warnings-as-errors -Xcc -Wall -Xcc -Wextra -Xcc -Werror
mkdir work/audioqueue-first-start work/audioqueue-control work/reference-server
cp docs/research/experiments/audioqueue-first-start/first-start/main.swift \
  docs/research/experiments/audioqueue-first-start/first-start/build.sh \
  docs/research/experiments/audioqueue-first-start/first-start/check-offline.py \
  work/audioqueue-first-start/
cp docs/research/experiments/audioqueue-first-start/registration/main.swift \
  docs/research/experiments/audioqueue-first-start/registration/build.sh \
  work/audioqueue-control/
cp docs/research/experiments/audioqueue-first-start/run-with-watchdog.py \
  work/run-audioqueue-first-start.py
bash work/audioqueue-first-start/build.sh \
  "$PWD/work/audioqueue-first-start-build/.build/arm64-apple-macosx/debug"
bash work/audioqueue-control/build.sh
```

The first-start build writes object, module, source, binary, and scratch-provenance hashes to its `build-manifest.json`.
Rebuilt binaries can differ across toolchains or paths; the archived manifest identifies the binaries used for the recorded observations.

## Generate and check the original fixture

These commands generate only the quiet synthetic WAV and run offline checks without AudioQueue or HAL calls.
Both helpers reject any file whose SHA-256 or complete integer payload differs from the canonical 220,500-frame reference.
The expected WAV SHA-256 is `43728e416e9d6c4b27f03a46aecc604e3353ee1d51dec8b0fcb2037a2f2cd58e`.

```sh
work/audioqueue-first-start-build/.build/arm64-apple-macosx/debug/filo-lab fixture \
  --file work/reference-server/filo-reference-44100-24.wav \
  --hz 44100 --bits 24 --seconds 5
python3 work/audioqueue-first-start/check-offline.py
work/audioqueue-control/audioqueue-registration --offline-check \
  --reference work/reference-server/filo-reference-44100-24.wav
work/audioqueue-control/audioqueue-registration --signal-check
```

## Recheck the archived receipts without audio

The [analysis runner](analyze-receipts.py) was adapted after the original audit from its two inline Python commands; it is not a script frozen before that audit.
With the retained measured helper binary, it reproduced every field of the archived independent analysis except its fresh creation timestamp.
An altered aligned hash was rejected, and an existing output file was preserved.
The following command needs the generated canonical WAV but neither an audio device nor a rebuilt helper:

```sh
python3 docs/research/experiments/audioqueue-first-start/analyze-receipts.py \
  --reference work/reference-server/filo-reference-44100-24.wav \
  --evidence-dir docs/validation/audioqueue-first-start \
  --helper-source docs/research/experiments/audioqueue-first-start/first-start/main.swift \
  --output work/audioqueue-receipt-analysis.json
```

Without `--helper-binary`, it explicitly reports that the original binary was not independently rehashed and only cross-checks the archived receipt/manifest hashes.
A new build must not be substituted as if it were the original binary; toolchain and path differences can change its hash.
The runner reconstructs expected capture bytes from the canonical reference and logged zero margins, not from an independently retained raw capture or Sony readback.

## Live measurement boundary

The preparation and offline commands above do not reproduce the live measurements.
The registration helper's normal mode creates, binds, and disposes an unstarted queue on BlackHole; registration and default-volume readbacks alone are not playback evidence.
The first-start helper's normal mode changes the default route through a recovery lease, captures a private process tap, and takes exclusive ownership of the selected physical output.
Use the recorded [protocol](../../../validation/audioqueue-first-start/protocol.json), including the external 45-second process-group watchdog and before/after state checks, for any separately authorized live rerun.
Invoke the copied watchdog as `python3 work/run-audioqueue-first-start.py --mode default --stem default-first-start`, or use `--mode explicit-unity --stem unity-first-start` for the other arm.
Its repository resolution requires that exact `work/run-audioqueue-first-start.py` location, and its output names and physical device selection match the measured WALKMAN setup.
Each mode needs a fresh process and a new receipt path, and the first-start helper requires the entire reference plus at least two seconds of exact zero tail to pass.
Enqueued frames and returned reusable buffers remain separate from the independently compared physical-device callback bytes.
