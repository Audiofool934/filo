# Spotify rejected-input onset observation

Measured on 2026-09-25 with Spotify 1.3.0.277, macOS 26.6.2, BlackHole 2ch, and Sony NW-ZX706 in USB DAC mode.
This extends the [connected Spotify measurements](spotify-exclusive-observation.md) by retaining the first rejected callback from the original synthetic WAV.
It identifies a precise transformation in one failed start, not the component responsible for it or a reliable playback workaround.
The [evidence index](../validation/spotify-onset/index.json) records executable and artifact hashes, settings, commands, and run order.

## Measurement and controls

The development laboratory executable had SHA-256 `1415bf023fc299725995fd3c535407f6100c2ee69b08ed551758b215dc505f4c`.
Both runs enabled the new default-off `--inspect-rejection` option and used a 40-second capture window.
Only the original five-second WAV was selected in Spotify's filtered local-file view, with repeat and shuffle off and no manually queued tracks.
Autoplay was temporarily off, Downloads and My Music were excluded, and only the synthetic fixture folder was enabled.
Player volume was 1; normalization, EQ, crossfade, and mono were off; gapless and Automix remained on.
No subscription audio was played or captured by this experiment.

The canonical WAV SHA-256 is `43728e416e9d6c4b27f03a46aecc604e3353ee1d51dec8b0fcb2037a2f2cd58e`.
It contains 220,500 stereo frames at 44.1 kHz and 24-bit precision.
The output used matching non-mixable signed32 virtual and physical formats, with WALKMAN held in Hog Mode.
The initial default output was MacBook Pro Speakers at 48 kHz, with WALKMAN at 192 kHz and BlackHole at 44.1 kHz using its Internal Fixed clock.

| Run | Result | Evidence |
| --- | --- | --- |
| First WAV selection after route preparation | Representation fault 5; the first rejected 512-frame callback retained; no complete original-reference anchor at the output | [Receipt](../validation/spotify-onset/spotify-rejection-first-wav.json) |
| Same-file repeat after cleanup and identical route preparation | All 220,500 frames and 1,764,000 signed32 bytes passed; no rejection snapshot or fault | [Receipt](../validation/spotify-onset/spotify-rejection-repeat-wav.json) |

The repeat's aligned output SHA-256 is `8fd04325bfb401bac8d2700c967453319a12e7ead41dde6ee04505e64e118ea5`.
Both runs reported no invalid buffers, overflow, underflow, timestamp errors, or cleanup errors apart from the first run's explicit representation failure.
This is a single ordered first-start/repeat pair, not a controlled failure-rate estimate.

## Rejected input

The first failure is at callback frame 1, left channel, with raw Float32 bits `0x35ed8107`.
Its exact value is `1.76954279140773e-6`, or `14.844000816345215` in 24-bit integer units and `3800.064208984375` in 32-bit integer units.
It is finite and within range but cannot be represented exactly at either integer precision.
The retained callback contains 1,024 sample words; 1,022 fall outside the 24-bit grid and 990 outside the 32-bit grid.
No non-finite samples or negative zeros were observed.
The [strict offline analysis](../validation/spotify-onset/spotify-rejection-first-wav-analysis.json) found no four-frame exact stereo anchor anywhere in the unmodified reference.
The count of accepted tap frames before the callback is not a source-file offset.

A separate exploratory model reproduces all 1,024 words exactly from the first 512 reference frames multiplied by a shared exponential gain onset.
It starts at gain zero, uses `alpha = Float32(0.002)`, rounds `1 - gain` to Float32, updates the gain with one final rounding of the multiply-add, and rounds each reference-times-gain product to Float32.
The inferred gains begin near 0, 0.002, 0.003996, and 0.005988008, reaching approximately 0.640494 at frame 511.
This numerical signature describes the captured window only.
It does not prove that the player or operating system uses this implementation, that the same model extends beyond the callback, or that reversing the gain could recover original source bits.
The production verifier does not apply this model, fit gain, round samples, or change its pass criteria.
The [model and negative controls](../validation/spotify-onset/spotify-rejection-onset-model-analysis.json) disclose that the coefficient was selected after inspecting the captured values.
Two related single-round update formulations match, so the observations do not uniquely identify an internal arithmetic expression or a fused machine instruction.
Only source offset zero survived the bounded search of all 219,989 fully contained nonnegative offsets for this model.
Unity gain, a linear ramp, nearby coefficients, a one-frame offset, a channel swap, and a one-bit corruption did not reproduce the complete window.

Reproduce the offline analyses from the repository root with a freshly generated canonical fixture and new output paths:

```sh
mkdir -p work
.build/debug/filo-lab fixture --file work/onset-reference.wav --hz 44100 --bits 24 --seconds 5
python3 docs/validation/spotify-onset/analyze-rejected-reference.py \
  --reference work/onset-reference.wav \
  --report docs/validation/spotify-onset/spotify-rejection-first-wav.json \
  --output work/onset-rejection-analysis.json
python3 docs/validation/spotify-onset/analyze-spotify-rejected-onset.py \
  --reference work/onset-reference.wav \
  --report docs/validation/spotify-onset/spotify-rejection-first-wav.json \
  --repeat-report docs/validation/spotify-onset/spotify-rejection-repeat-wav.json \
  --output work/onset-model-analysis.json
```

Both tools require the canonical reference hash and refuse to overwrite their output files.
The strict analyzer has 28 offline controls plus separate CLI checks; its unchanged repeat analysis correctly reports no retained rejection without treating that absence as a pass.

## Separate BlackHole loopback confound

The required silent rendered-loopback matrix initially failed all eight rate/depth cases, while a process-tap-only control passed exactly.
An immutable previous executable also failed the same loopback control, so this failure was not specific to the new bridge diagnostics.
Read-only inspection found BlackHole's aliased master input/output level at scalar 0.5, reporting -32 dB, with mute off.
The [BlackHole v0.5.0 source](https://github.com/ExistentialAudio/BlackHole/blob/v0.5.0/BlackHole/BlackHole.c#L4536-L4564) applies its master gain in the loopback ReadInput path.
Its actual scalar setter maps 0.5 to -32 dB, approximately 0.025118864 amplitude, rather than half amplitude.
This is a separate post-tap gain from the Spotify onset model: the Spotify repeat passed through the exclusive output while BlackHole's level was still 0.5.
The read-only property snapshot overlapped the parent's reference run, so its routing and clock fields are not an atomic idle-state snapshot.
A temporary unity-gain control passed the formerly failing 44.1 kHz / 24-bit case.
The universal beta.3 laboratory then passed all eight [rendered-loopback cases](../validation/spotify-onset/rejection-unity-loopback-matrix.json), covering 44.1, 48, 96, and 192 kHz at both 16-bit and 24-bit precision.
All comparisons had zero mismatches, and the matrix restored BlackHole's original rate.
This control supports the virtual-device gain explanation for the separate loopback failures.
The temporary level holder reported an ambiguous control-tuple mismatch and skipped automatic restoration, without retaining the differing tuple.
That label does not establish an external writer or a user change.
After stopping all test I/O, parent cleanup twice confirmed that both aliases still matched the task-applied unity state, conditionally restored the original scalar once, and twice verified 0.5 / -32 dB with mute off.
The [separate restoration receipt](../validation/spotify-onset/rejection-level-conditional-restoration.json) preserves this distinction; the original holder journal remains retained locally.

## Limits and restoration

The sample-bearing diagnostic is opt-in and bounded to one rejected callback, with at most 8192 stereo frames.
It allocates and pre-touches storage before audio callbacks and reads it only after both IOProcs have been released.
Normal application playback does not enable this storage.
An absent snapshot is not proof that the input was valid.

After the two Spotify runs, independent device, WALKMAN-format, and BlackHole-clock snapshots exactly matched their initial states.
The same three comparisons passed again after the later loopback matrix and volume restoration.
Spotify Autoplay, Downloads, and My Music were restored on; the synthetic source was disabled and Show Local Files restored off.
The player remained paused and the existing processing controls were preserved.
Neither test measures the USB payload or PCM received inside the Sony device.
No end-to-end or subscription-master claim follows from these results.
