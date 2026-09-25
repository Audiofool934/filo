# Spotify tap-autostart evidence

This bundle preserves three original-synthetic Spotify attempts using the same scratch `filo-lab` executable with tap autostart disabled.
The [observation](../../research/spotify-tap-autostart-observation.md) explains coverage, mode uncertainty, and the exact retained onset comparison.
The first attempt is a coverage failure; both timestamped retries failed with the same retained transformation, including the final user-confirmed USB DAC mode condition.
Earlier USB DAC mode intervals remain unknown.

The measurement JSON, watchdog JSON, UI timing JSON, process-exit observations, stderr logs, and three wrapper sources are copied byte-for-byte.
The [archive provenance](archive-provenance.json) identifies the contextual records sanitized for privacy and mode clarity, including their original source hashes.
The [index](index.json) records public artifact hashes and dependency hashes.
Device identity snapshots, audio, and executables are not published.

## Reproduce the numerical audit without audio

The analyzer was adapted after the live observations from the task-only offline audit.
It is not a preregistered analysis executable and does not claim its output is byte-identical to the earlier task-only JSON.
It imports the existing [strict rejection analyzer](../spotify-onset/analyze-rejected-reference.py) to validate fixture identity, every generator sample, rejection bounds, offender metadata, integer grids, and exact unchanged-audio anchors.
It reads the [prior onset receipt](../spotify-prewarm/onset2-original-after-silence.json) and [frozen model result](../spotify-onset/spotify-rejection-onset-model-analysis.json) from this repository.
The model coefficient and offset are fixed, and no fitting or correlation search occurs.
The result has no wall-clock timestamp or absolute input paths, so repeated analysis of the same bytes is deterministic.

Run from the repository root with a new output filename:

```sh
python3 docs/validation/spotify-tap-autostart/analyze-receipts.py \
  --reference work/reference-server/filo-reference-44100-24.wav \
  --evidence-dir docs/validation/spotify-tap-autostart \
  --output work/spotify-tap-autostart-offline-analysis.json
cmp docs/validation/spotify-tap-autostart/independent-analysis.json \
  work/spotify-tap-autostart-offline-analysis.json
```

The expected WAV file SHA-256 is `43728e416e9d6c4b27f03a46aecc604e3353ee1d51dec8b0fcb2037a2f2cd58e`.
If it is absent, generate it using the existing fixture command with a fresh path:

```sh
dist/filo.app/Contents/MacOS/filo-lab fixture \
  --file work/tap-autostart-reference.wav --hz 44100 --bits 24 --seconds 5
```

Pass that new path as `--reference` in the analysis command.
The fixture subcommand only writes the known synthetic file; it does not play it or create a capture session.
The analyzer rejects an altered or truncated fixture, inconsistent offender metadata, unexpected receipt accounting, mismatched onset words, and any existing output file.
Its successful exit means the archived observations are numerically consistent, not that playback passed.
The [offline checks](offline-checks.json) record deterministic reruns and negative controls.

## Recorded live build and command provenance

The unchanged [scratch-build provenance](scratch-build-provenance.json) pins source commit `4e77ac5f65d98359fe8bec4c3c3cb118bae6e822` and one source substitution: `kAudioAggregateDeviceTapAutoStartKey: true` to `false`.
The repository main revision at measurement preparation was `8a31a07690f3df71a23c0aa4d3ece4c67540386c`.
The [existing scratch preparation script](../../research/experiments/audioqueue-first-start/prepare-scratch.py) reconstructs the pinned source without changing the checkout, building, or accessing audio.
Its original relay-source hash is `8996bddd5f4a5282c149918503f4e71eb93f716968ab302fa3b4373e3734eb14`; the substituted source hash is `7bcf5dbbc7e4ff56ca6195c89d851c08285b66b37354194e4757aff9e762b144`.
The measured scratch executable hash is `817c8e525c860ecb7a9db5203c0e31941df98d97b1f143e7eed867c510408e0c`.

The original preparation and build use a new scratch directory:

```sh
python3 docs/research/experiments/audioqueue-first-start/prepare-scratch.py \
  --repository "$PWD" --output-dir work/audioqueue-first-start-build
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
xcrun swift build --package-path work/audioqueue-first-start-build \
  --configuration debug --product filo-lab \
  -Xswiftc -warnings-as-errors -Xcc -Wall -Xcc -Wextra -Xcc -Werror
```

A rebuild may differ byte-for-byte because of toolchain or path differences and must not be represented as the measured executable.
The offline analyzer cross-checks recorded executable hashes but does not independently read an executable.

The three exact wrapper snapshots are [run.py](run.py), [run-retry.py](run-retry.py), and [run-dac-mode-on.py](run-dac-mode-on.py).
They were executed from their original `work/spotify-tap-autostart/` location and resolve the repository relative to that location.
They are frozen research snapshots, not runnable in-place archival tools or app features.
Each selected the sole canonical file at `work/spotify-tap-autostart/fixture/filo tap autostart reference 44100 stereo 24bit WAV.wav` and refused existing report paths.
Their effective measurement command was:

```text
work/audioqueue-first-start-build/.build/arm64-apple-macosx/debug/filo-lab \
  verify-reference --device WALKMAN --source "BlackHole 2ch" \
  --reference CANONICAL_REFERENCE.wav --player com.spotify.client \
  --seconds CAPTURE_SECONDS --inspect-rejection
```

The first wrapper requested 30 seconds under a 90-second watchdog; the two retries requested 60 seconds under 120-second watchdogs.
The wrappers do not control the player, timestamp source rendering, or prove receiver state.
The initial wrapper did not retain armed-event timestamps; the later two timestamped received stderr lines and were paired with separately recorded UI dispatch times.
Actual live reruns require separately prepared player, device-mode, routing, exclusive-access, and restoration conditions; the offline commands above do not perform them.
Forced watchdog termination would require recovery inspection, but all three recorded runs exited normally with verification failure.
