# Exclusive output and verification

The 1.1 beta adds a working separate-source exclusive relay and a laboratory for measuring whole known references.
It does not certify arbitrary Apple Music or Spotify tracks as end-to-end bit-perfect.
The distinction is an evidence boundary, not a difference between a 24-bit and a 32-bit label.

## Playback path

```text
Selected music app -> BlackHole 2ch at the selected nominal rate
                   -> private process-specific tap
                   -> preallocated sample FIFO
                   -> matching non-mixable integer output IOProc
                   -> macOS USB audio driver -> DAC
```

filo owns the physical DAC with Hog Mode.
The capture aggregate contains only the virtual source, so it does not depend on access to the hogged DAC.
Matching virtual and physical integer ASBDs remove an implicit float-to-integer conversion from the physical callback boundary.
The bridge packs representable samples exactly into the negotiated integer words.
It refuses rounding, clipping, dithering, resampling, unsupported layouts, and non-finite values.
Widening a 16-bit or 24-bit sample to an integer 32-bit container preserves its value and adds no source information.

A preallocated single-producer/single-consumer FIFO connects the two independent IOProcs.
A bounded control loop changes BlackHole's virtual clock cadence to follow the DAC, without editing audio samples.
The initial queue reserve is measured after startup because opening a physical USB output can block while input continues.
Underflow, overflow, unrepresentable samples, or discontinuous callback sample times latch a failure.
The control queue also checks device identity, Hog ownership, exact formats, clock ownership, and callback progress.
The audio callbacks do not allocate, lock, log, access files, or run Swift code.

## Requirements and setup

- macOS 14.4 or later.
- An already installed [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole) with its adjustable virtual clock control.
- A DAC exposing one stereo stream and matching non-mixable integer virtual/physical formats.
- System-audio capture permission, player metadata access, and any Microphone permission macOS requests for BlackHole's virtual input.

filo does not bundle or install BlackHole.
Its clock adapter uses the documented [virtual clock control](https://github.com/ExistentialAudio/BlackHole/wiki/Adjust-Virtual-Clock).
No driver implementation code is copied into filo.
The hardware validation currently covers Sony WALKMAN NW-ZX706 only.
Other devices can reject the required format or ownership request.

Set listening level on the DAC before using unity player volume.
For original stereo PCM, disable EQ, normalization, spatial processing, AutoMix/crossfade, and track-specific gain.
filo reads the subset of controls exposed by each player's scripting interface and blocks known processing.
Unreadable, stale, or unsupported controls remain unknown.
It never turns unknown state into a verified result.
The app does not change these player preferences itself.

Select **Exclusive preview**, your DAC, and a known rate where possible.
The explicit-rate path can be armed before playback; automatic Music format detection remains reactive and cannot certify the beginning of a track.
The preview takes over the media output route with BlackHole while connected.
Only the selected player's process is forwarded to the DAC; other applications using that virtual default can become inaudible.
System alerts keep their separate existing device selection.
Disconnect returns settings still owned by filo.

A reported pause ends one measured segment.
Resuming, replacing a process, or changing a format creates another segment where required.
A failed transfer is shown as a stopped connection, not silently joined into a claim of continuous sample identity.
There is no gapless or arbitrary automatic-rate bit-perfect guarantee.

## Evidence levels

| Observation | What it establishes |
| --- | --- |
| Matching source policy and device rate | Format configuration only; the source label may be a manual choice or Spotify policy. |
| Equal virtual/physical integer format plus Hog Mode | Configuration and output ownership at the HAL boundary. |
| Synthetic sequence equal at actual output callback | The measured relay segment preserves the known samples. |
| Entire lossless reference equal as raw output bytes | The tested player and host path preserve that complete reference under the recorded conditions. |
| Independent USB payload capture or receiver-side bit test | Evidence at the actual device-bound transport or receiver boundary. |

A callback measurement does not independently observe the driver, USB wire, or Sony receiver.
Sony's format display reports codec/rate/depth, not a checksum of received sample values.
The reviewed Sony documentation provides no receiver-side PCM readback or known-pattern bit test.
The available Mac exposes no enabled passive USB payload capture interface.
See the [endpoint investigation](research/endpoint-verification.md) for primary sources, host observations, and the remaining measurement gap.

Apple Music does not expose supported exact per-track PCM metadata for every subscription path.
Spotify's 44.1 kHz option is a policy, not a measurement of the current master.
A passing local reference cannot certify another subscription track, player version, DSP setting, or rate transition.

The tested Apple Music 1.6.6 path did not pass the known-reference check on macOS 26.6.2.
HTTP-resource and imported local-file playback produced byte-identical changed samples at the process tap, before the exclusive bridge.
The opening was altered and later samples contained much smaller floating-point differences despite essentially unity gain.
The strict bridge rejected those values instead of silently rounding them.
This preview therefore cannot provide uninterrupted exact playback through that tested Music path; see the [source observation](research/music-reference-observation.md) for the measurements and limits.

## Reproduce laboratory measurements

Build with a licensed compatible Xcode or an available Command Line Tools toolchain.
Use a low listening level: these commands send quiet synthetic audio to the named physical device.

```sh
swift build
.build/debug/filo-lab formats --device WALKMAN
.build/debug/filo-lab verify-exclusive --device WALKMAN --source 'BlackHole 2ch' --bits 24 --seconds 120
.build/debug/filo-lab fixture --file reference.wav --hz 44100 --bits 24 --seconds 5
.build/debug/filo-lab verify-reference --device WALKMAN --source 'BlackHole 2ch' --reference reference.wav --seconds 45
```

The synthetic relay test measures a segment of the emitter's deterministic sequence.
Its reported source offset is not a whole-track proof.
For a complete synthetic fixture with a prearmed relay, one-time start handshake, and silent postroll, run the optional repository harness:

```sh
mkdir -p work
bash scripts/verify-finite-reference.sh --output WALKMAN --receipt work/whole-reference.json
```

It accepts only filo's original quiet five-second 44.1 kHz / 24-bit fixture and never overwrites the receipt.
The [published harness reproduction](validation/exclusive-finite-reference-reproduction.json) passed complete raw-byte comparison on the WALKMAN.
Its source is a synthetic emitter; use the separate `verify-reference` player command to investigate Music itself.
The reference command first prepares the virtual source rate and route, allows a closed player to be launched, then prints when capture is armed.
Play the exact known reference from its beginning within the capture window.
Use only reference material you own; do not use the command to record subscription audio.
The laboratory holds captured reference data in memory and outputs a structured comparison rather than saving a music recording.
The normal app allocates no reference-capture storage.

The raw verifier independently serializes expected integer words from the decoded reference.
It checks valid-bit precision, byte order, padding, entire prefix/tail coverage, exact sample order, and SHA-256 hashes.
It uses one unambiguous 32-frame anchor and one fixed alignment, with no internal re-alignment or gain normalization.
Missing samples, extra non-silent material, incomplete coverage, wrong rate, or even a single padding-bit change fail the whole-reference result.
A float-only comparison can hide low-bit corruption; the raw-byte verifier is tested against that case.
Callback timestamp evidence and cleanup errors are also part of the laboratory pass condition.

## Recovery

The exclusive recovery journal is separate from the media route lease.
It stores original, confirmed, and pending state for coupled DAC rate/physical/virtual formats and the virtual clock.
Each hardware mutation has a persisted intent before it is applied.
A process-held advisory lock prevents concurrent filo processes from recovering another live session.
Devices, streams, and clock controls are resolved again from persistent identity instead of trusting stale AudioObjectIDs.
Clock-control discovery retries the transient object rebuild during a BlackHole clock-source switch.

Restoration stops IO first and restores the DAC rate, physical format, and virtual format as one owned group.
It then restores observable virtual-clock state and the media route.
If the user or another application changes a group, filo preserves that change.
Failed restoration and disconnected devices retain recovery records for a later retry.
A failed IOProc destruction retains its callback memory instead of freeing a possibly live context.
Atomic journal replacement protects process-crash recovery; the journal does not promise durability through power loss.

To retry orphaned exclusive settings without opening the GUI:

```sh
.build/debug/filo-lab recover
```

Do not edit recovery records while a connection is active.
The journal contains local device identifiers and must not be copied into a public issue without redaction.
