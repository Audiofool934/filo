# Apple Music known-reference tap observation

The observed Apple Music path did not reproduce the complete original fixture exactly at the process tap.
Its opening contains a substantial transformation lasting roughly 46 ms, and its remaining samples contain much smaller floating-point differences despite stable alignment and essentially unity gain.
The complete transformed audio is byte-identical in separate HTTP-resource and imported-local-file playback captures.
This capture does not establish which Music or CoreAudio component caused either behavior.

## Scope and provenance

The test ran on Apple Silicon with macOS 26.6.2, build 25G83, and Music 1.6.6, build 1.6.6.
Those version values were read directly from the operating system and Music's installed `Info.plist` during offline analysis.
The source was filo's original quiet synthetic stereo fixture, 220,500 frames at 44.1 kHz and 24-bit precision, encoded to ALAC.
The first run served that ALAC to Music through a local HTTP server supporting range requests.
The second run imported the same local ALAC into Music and played the imported five-second song row.
Before that local-file run, Music was freshly launched after the BlackHole source route had been set to 44.1 kHz.
The helper independently decoded that ALAC and checked every sample against the generated fixture before arming the tap.
No subscription recording or DRM extraction was involved.

The supervising agent verified AutoMix off, Dolby Atmos off, Sound Check off, Sound Enhancer off, Music volume 1.0, and BlackHole volume at unity for this session.
The offline analysis did not change or independently query those controls.
Both HTTP-resource and imported-local-file playback were tested, but only for this fixture and configuration, so the result should not be generalized to every local file or subscription playback path.

The capture used an unmuted Music process tap pinned to BlackHole 2ch at 44.1 kHz, with `relay: false`.
The HTTP run observed 1,033,728 stereo Float32 frames and the local-file run observed 585,728, with no invalid buffer layouts and no route-restoration errors in either run.
The exclusive integer relay and physical DAC were absent from this recording path.

The complete numeric results, input hashes, environmental metadata, fit coefficients, and window checks are in [the sanitized analysis record](../validation/music-reference-tap-analysis.json).
The reproduction script remains a temporary laboratory artifact at `work/analyze-reference.py`.
The report contains no device UID or absolute user path.

## Reproduction across HTTP and local-file playback

Only silence outside each complete active stereo-frame span was removed for this comparison.
All bytes inside the spans were compared, including legitimate zero-valued individual samples and the altered opening.

| Observation | HTTP resource | Imported local file |
| --- | ---: | ---: |
| Captured frames | 1,033,728 | 585,728 |
| First active capture frame | 7,168 | 9,728 |
| Last active capture frame | 227,668 | 230,228 |
| Active span frames | 220,501 | 220,501 |
| Nonzero individual samples | 440,972 | 440,972 |
| Off-24-bit-grid samples | 282,326 | 282,326 |

The two active spans are exactly equal across 1,764,008 bytes, or 441,002 Float32 sample words, with zero differing words.
Both active spans have SHA-256 `3aa0a6aab2d9bb85dcd9f70f45cf089e00fd9aceeb031694ffa301e0b72caffd`.
Their start times and surrounding silent recording lengths differ, but their complete onset, steady content, and ending do not.
The transformation therefore reproduces in both tested resource paths, which does not support an HTTP-only explanation.
It still does not identify the responsible processing component or show that all Music playback paths behave identically.

## Alignment and complete frame coverage

The detailed numerical analysis below uses the HTTP capture, with the same results applying to the byte-identical local active span after its additional 2,560 leading silent frames are accounted for.
Independent cross-correlation of the left and right channels gives the same reference offset of HTTP capture frame 7,169, corresponding to frame 9,729 in the local-file capture.
The nonzero HTTP capture extends from frame 7,168 through frame 227,668, inclusive, spanning 220,501 stereo frames.
There is one additional nonzero stereo frame immediately before the aligned reference and no nonzero samples after its final frame.
All 26 tested steady-state windows, each 8,192 frames long, retain zero additional integer lag within the tested plus-or-minus-four-frame range.
There is no evidence of continuing frame insertion, deletion, or drift in that steady section.

The capture contains 440,972 nonzero individual samples.
Dividing that count by two gives 220,486, but that is not its frame length because individual samples can legitimately be zero while the other channel in the frame remains nonzero.
The apparent 14-frame shortage therefore does not demonstrate truncation.

## Measured differences

Errors use one signed 24-bit integer step as the unit, abbreviated LSB24.
The fixture is intentionally quiet, roughly -60 dBFS peak, so error sizes here cannot be extrapolated to all music or larger amplitudes.

| Reference section | Raw error RMS, LSB24 | Maximum absolute error, LSB24 | Samples differing after nearest-24-bit rounding |
| --- | ---: | ---: | ---: |
| Opening, frames 0 through 2,047 | 2,461.43503 | 12,021.0693 | 3,782 of 4,096 |
| Steady portion, frames 2,048 through 220,499 | 0.00037442713 | 0.00244140625 | 0 of 436,904 |
| Final 1,024 frames | 0.00037189609 | 0.00146484375 | 0 of 2,048 |

Every steady sample rounds back to the original 24-bit integer value, including the final reference frame.
Only 158,670 of those 436,904 steady Float32 samples are exactly equal before rounding.
Their fitted left and right gains are 0.999999966878 and 0.999999966914, respectively.
The steady error is approximately -207.0 dBFS RMS, with a maximum absolute error approximately -190.7 dB relative to full scale.
These tiny differences still violate exact Float32-to-integer representability, which explains the bridge's strict rejection without implying a perceptible steady-state loss of fidelity.
Nearest-integer rounding is used only as an offline diagnostic and is not a proposed change to the production bridge.

## What the opening supports

A constant gain change or a simple gain fade applied to the same sample does not adequately describe the opening.
Short FIR fits place most of their weight on reference samples x[n] and x[n+2], with the latter contribution falling toward zero during startup.
The weights below come from nine-tap fits over 64-frame stereo windows, so they are descriptions rather than identification of a particular implementation.

| Window start frame | Weight on x[n] | Weight on x[n+2] |
| ---: | ---: | ---: |
| 8 | 0.188797 | 0.666849 |
| 128 | 0.258411 | 0.647289 |
| 512 | 0.521435 | 0.466176 |
| 1,024 | 0.849537 | 0.150245 |
| 1,536 | 0.989356 | 0.010834 |
| 1,856 | 0.999857 | 0.000161 |
| 2,048 | 1.000000 | approximately zero |

A smooth two-delay model fitted on alternating training frames predicts held-out opening frames with 20.0142 LSB24 RMS error.
This supports a time-varying mixture or transition process as a useful description.
Errors exceeding 0.003 LSB24 end at reference frame 2,036, approximately 46.190 ms after the aligned beginning.
Errors exceeding half a 24-bit step end at reference frame 1,943.
The final 1,024 frames do not show a comparable fade or changing delay.

## What remains unresolved

The stable steady-state lag and recovery of every steady 24-bit value after rounding do not support a substantial ongoing sample-rate mismatch.
An identity-rate processing stage or floating-point round trip remains compatible with the small steady errors.
The fitted steady cross-channel coefficients, 3.21e-10 and 8.11e-11, do not indicate meaningful linear stereo mixing in that section.
Startup interpolation, mixing, or transition processing is compatible with the opening, but neither a specific resampler nor a particular Music feature has been established.
The settings above must not be treated as proof that every undocumented processing stage was bypassed.

The transformation is present at the observed process-tap boundary before filo's exclusive bridge and DAC output.
Changing the downstream integer serializer cannot restore the altered opening samples.
This evidence does not support an end-to-end bit-perfect claim for the tested Music path.
The local-file versus HTTP comparison is now complete for this fixture and produced identical active PCM.
Further localization requires controlled comparisons against a direct synthetic emitter or an independent player, and repeated runs with one route or launch-history factor changed at a time.

## Measured complete-fixture relay test

A separate finite synthetic-source experiment passed first-to-last verification at the connected WALKMAN's actual signed32 output callback.
The [measurement receipt](../validation/exclusive-finite-reference-44100-24.json) records all 220,500 reference frames and 1,764,000 reference bytes with zero mismatching frames, sample words, bytes, or padding.
The 53,760 leading frames and 118,956 trailing frames were silent.
The expected and actual aligned byte hashes both equal `8fd04325bfb401bac8d2700c967453319a12e7ead41dde6ee04505e64e118ea5`.
Emitter, capture, and output timestamps had no missing evidence or discontinuities; the bridge had no underflow, overflow, representation failure, or latched fault, and cleanup returned no errors.

The bounded laboratory helper uses existing `ExclusiveRelaySession`, `ReferencePCM`, and `OutputByteVerification` code.
Its source is a finite emitter with a preallocated Float32 stereo buffer and atomic start/completion flags, not Music or a product player.
The measured sequence was:

1. Load and validate the original fixture before starting audio, then spawn a child emitter that continuously outputs zeros to BlackHole and reports that its IOProc is running.
2. Resolve that child PID's HAL process and start the exclusive relay with bounded raw-byte capture already enabled.
3. Wait for the bridge to prime and its callbacks and timestamps to advance without faults, then send a one-time `GO` command to the child.
4. The child emits the fixture exactly once from frame zero, including a partial final callback if necessary, then continues emitting zeros without stopping its IOProc.
5. Keep the relay running long enough to deliver the fixture's last frame and a confirmed silent tail, rather than stopping as soon as the source reports completion.
6. Stop both relay callbacks, inspect the final fault and timestamp metrics, and pass the actual written integer bytes to `OutputByteVerification.compare` against the independently loaded complete reference.
7. Require complete-reference equality, matching raw hashes, zero mismatching bytes and padding, silent prefix and tail, no missing timestamp evidence, and clean restoration before reporting success at this software boundary.

The handshake removes the existing `verify-exclusive` command's unavoidable late attachment to an already advancing source pattern.
Continuous silence before and after the finite fixture prevents an intentional source stop from being confused with a relay underrun.
The test fails rather than resetting or retrying its sequence after a fault.
This establishes complete synthetic-fixture coverage through the physical device's software callback for this run, while USB receiver delivery and Music's independent source behavior remain separate questions.

The optional repository harness is [scripts/verify-finite-reference.sh](../../scripts/verify-finite-reference.sh), with its finite emitter and parent/child controller under `scripts/lab/`.
The published measurement used the temporary laboratory precursor; the repository copy preserves the C emitter and measurement sequence while adding explicit reference and receipt arguments, a portable build wrapper, and a persistent route-recovery journal.
The repository wrapper then built from a fresh temporary directory and repeated the hardware experiment successfully.
Its [separate reproduction receipt](../validation/exclusive-finite-reference-reproduction.json) records the published source hashes, complete 220,500-frame raw-byte equality, clean callback evidence, and restoration of the known hardware baseline.

```sh
scripts/verify-finite-reference.sh --output WALKMAN --receipt /path/to/new-result.json
```

The receipt directory must already exist, and an existing receipt is never overwritten.
Without `--reference`, the wrapper generates the original quiet five-second 44.1 kHz / 24-bit fixture in its temporary build directory.
An explicitly supplied reference must reproduce that exact generated fixture; arbitrary music is rejected before audio starts.
The wrapper requires an installed BlackHole 2ch device and a DAC with matching exclusive signed32 callback and physical formats.
It removes its temporary build and fixture files on exit, while the requested receipt and any necessary persistent recovery records remain.
Use `scripts/verify-finite-reference.sh --check` to compile the harness and print its help without touching audio hardware.
