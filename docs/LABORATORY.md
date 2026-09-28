# Audio laboratory

[Back to the documentation index](README.md) · [Architecture](ARCHITECTURE.md) · [Validation](VALIDATION.md)

`filo-lab` is filo's command-line audio laboratory.
It measures whether filo's audio paths preserve known samples exactly, and it can retry recovery of interrupted settings.
It is separate from normal playback: the app never allocates test capture storage or saves music.

## Safety rules

- **Use BlackHole for silent tests.** Synthetic tests on a physical device are audible; lower the listening level first.
- **Use only reference material you own.** Never use the laboratory to record subscription audio or publish it as a fixture.
- **Check BlackHole's controls.** Rendered loopback includes the virtual device's gain and mute, so set unity gain and mute off, note the original settings, and restore them afterwards.
- **Expect device changes.** Some commands change sample rates, the default output, Hog Mode, and BlackHole's clock.
  They restore what they still own, and `filo-lab recover` retries anything left behind.

## Getting the tool

Build it from the repository root:

```sh
swift build
.build/debug/filo-lab help
```

Every packaged app also contains it at `filo.app/Contents/MacOS/filo-lab`.
The optional tests use [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole), installed separately.

## Commands

Devices can be named by display name, UID, or CoreAudio object ID; `devices` lists them.
Every command prints JSON and exits with a nonzero status on failure.

| Command | Purpose |
| --- | --- |
| `devices` | List output devices with rates, formats, and Hog Mode owners. |
| `processes` | List CoreAudio audio processes. |
| `formats --device NAME` | Show a device's output streams and advertised formats. |
| `clock --device 'BlackHole 2ch'` | Inspect BlackHole's clock source selector and pitch control. |
| `rate --device NAME --hz RATE` | Set a device's nominal sample rate. |
| `recover` | Restore settings left by an interrupted app or laboratory session. |
| `emit --device NAME [--bits 16\|24] [--seconds 8]` | Play the deterministic quiet synthetic pattern. |
| `capture --device NAME --pid PID [--relay] [--seconds 5]` | Tap a process and report callback statistics. |
| `verify --device NAME [--bits 16\|24] [--relay] [--loopback] [--seconds 2]` | Tap a synthetic emitter and compare the capture with the reference. |
| `exclusive-probe --device NAME [--hz RATE]` | Acquire exclusive access and report the matching integer format, then release it. |
| `verify-exclusive --device NAME --source 'BlackHole 2ch' [--bits 16\|24] [--seconds 5]` | Relay a synthetic emitter through the exclusive bridge and compare the DAC callback's integer words. |
| `fixture --file REFERENCE.wav --hz RATE [--bits 16\|24] [--seconds 5]` | Write a quiet deterministic WAV reference; never overwrites a file. |
| `verify-reference --device NAME --source 'BlackHole 2ch' --reference FILE [--player com.apple.Music] [--seconds 45] [--inspect-rejection]` | Compare a complete known reference played by a real player against the DAC callback's raw output bytes. |

`--loopback` measures a virtual device's rendered input and requires `--relay`.
`--player` accepts `com.apple.Music` or `com.spotify.client`.
`--fixed-clock` disables virtual-clock following for short diagnostic runs of the exclusive commands.
`--exclusive` on `capture` and `verify` belongs to the unsupported 1.0 same-device experiment.
Durations are at least one second and at most 120 seconds, or 130 for `emit`.

## How comparison works

The synthetic pattern gives each channel a distinct, deterministic, quiet sequence that exercises many sample values and low bits.
Sine waves alone could miss low-bit or channel-order errors.

The comparator locates one fixed source offset from 32 consecutive exact frames, which allows startup latency and leading silence.
It then compares every remaining recorded frame in order.
It never normalizes gain, resamples, removes internal silence, or realigns after dropped or repeated samples.
Tests deliberately introduce gain, channel swaps, dropped and repeated frames, and silence to confirm the comparison fails.

These patterns are not a full-amplitude linearity test or an exhaustive enumeration of every 24-bit value through a DAC.

## Shared-path matrix

With BlackHole installed, run the silent matrix after building:

```sh
python3 scripts/verify-pcm.py --loopback
```

The script runs `verify --relay` at 44.1, 48, 96, and 192 kHz, each at 16 and 24 bits, and writes a report to `work/validation/pcm-matrix.json`.
With `--loopback`, it measures the rendered virtual-device input, which includes filo's output callback and the BlackHole path.
Without it, it measures the process-tap input while the relay runs.
Neither mode measures a physical DAC's input.
The script restores BlackHole's original rate if it still owns the rate it last set, and never changes BlackHole's gain or mute.
Use `--device` to test another output, which makes the test audible.

A longer single run:

```sh
.build/debug/filo-lab verify --device 'BlackHole 2ch' --bits 24 --relay --loopback --seconds 60
```

## Exclusive path

These commands send quiet synthetic audio to the named physical DAC, so lower its listening level first.

```sh
.build/debug/filo-lab formats --device WALKMAN
.build/debug/filo-lab verify-exclusive --device WALKMAN --source 'BlackHole 2ch' --bits 24 --seconds 120
```

`verify-exclusive` decodes the actual integer words written in the DAC's output callback and compares them with the reference.
It measures an exact segment of the emitter's continuous sequence; its reported source offset is not a whole-track result.

### Complete synthetic reference

For a complete finite reference with a prearmed relay, a one-time start handshake, and silent postroll, use the harness:

```sh
mkdir -p work
bash scripts/verify-finite-reference.sh --output WALKMAN --receipt work/whole-reference.json
```

It builds a fresh laboratory in a temporary directory, plays only filo's quiet five-second 44.1 kHz / 24-bit fixture exactly once, and never overwrites the receipt.
Without `--reference`, it generates that fixture temporarily.
`--check` compiles the harness and prints its help without touching audio hardware; CI runs it.

### Known reference through a real player

`verify-reference` checks whether a real player delivers a complete known file unchanged:

```sh
.build/debug/filo-lab fixture --file reference.wav --hz 44100 --bits 24 --seconds 5
.build/debug/filo-lab verify-reference --device WALKMAN --source 'BlackHole 2ch' --reference reference.wav --seconds 45
```

1. The command recovers any orphaned settings, makes BlackHole the default output at the reference's rate, and waits for the player process.
2. When it prints that capture is armed, play the exact reference from its beginning within the capture window.
3. It then compares the captured output bytes with the reference and restores the route after exclusive cleanup succeeds.

References can be WAV, AIFF, or ALAC with integer samples of at most 24 bits; lossy and unsupported files are rejected.
The verifier independently serializes the expected integer words from the decoded reference, rather than reusing the realtime bridge.
It checks valid-bit precision, byte order, padding, full prefix and tail coverage, exact sample order, and SHA-256 hashes, using one unambiguous 32-frame anchor and one fixed alignment.
Missing samples, extra non-silent material, incomplete coverage, a wrong rate, or a single changed padding bit fails the whole reference.
Callback timestamp evidence and cleanup errors are also part of the pass condition.
A float-only comparison could hide low-bit corruption; the byte verifier is tested against that case.

### Inspecting a rejected input

When a reference fails because the bridge rejected an input sample, add `--inspect-rejection` to `verify-reference`.
The receipt then includes a `rejectionSnapshot` with the exact Float32 bit words of up to 8,192 stereo frames from the first rejected callback, including up to 64 frames before the first rejected sample.
These are samples of your reference, so share the receipt only when the reference itself may be shared.
Inspection is off by default, available only on `verify-reference`, and never relaxes the comparison or passes rejected samples on.

- `acceptedFramesBeforeCallback` counts tap frames accepted earlier, including preroll; it is not a position in the original file.
- `captureStartFrame` and `firstRejectedFrame` are positions within the rejected callback.
- `sourceRepresentable` is absent when the source precision was not asserted.
- No snapshot means inspection was off, no representation failure occurred, or the callback could not be confirmed released.

A snapshot's presence or absence never establishes whole-reference equality.

## Recovery

```sh
.build/debug/filo-lab recover
```

`recover` restores orphaned exclusive settings first, then the route and rate lease, using the same journals as the app.
It prints any remaining errors and exits nonzero if something still needs recovery.

## Receipts

Published receipts live in [`validation/`](validation/) and contain configuration and statistics, not recordings or device serial numbers.
Their executable hashes describe the files present when each receipt was written, not an attestation of a loaded process image.
Local captures, screenshots, and scratch output belong in the ignored `work/` directory.
