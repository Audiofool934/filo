# Spotify connected exclusive-output observation

Measured on 2026-09-24 local time with Spotify 1.3.0.277, macOS 26.6.2 (25G83), and a Sony NW-ZX706 in USB DAC mode.
Six connected runs preserved our complete original five-second local reference through Spotify and filo to the actual WALKMAN software output callback.
Seven other runs stopped when the tap delivered samples that could not pass the exact integer representation check.
The result is conditional finite-playback success with an unresolved startup or selection failure, not a generally reliable Spotify bit-perfect mode.
No production application code was changed for these experiments.

The [aggregate index](../validation/spotify-exclusive/index.json) records the ordered runs, exact fixture and executable hashes, launch options, receipt hashes, numeric results, and sanitized device observations.
Each linked receipt is an unchanged copy of the JSON produced by its measurement executable.
Raw hardware snapshots, private device identifiers, binaries, and audio captures are not included in this archive.

## Reference and measured boundary

All files contain the same original deterministic 44.1 kHz stereo 24-bit reference, with 220,500 frames and nonzero first and last frames.
The existing [fixture manifest](../validation/spotify-reference-fixtures.json) independently verifies the WAV, ALAC, and FLAC decodes sample for sample.
The CLI compared against the canonical WAV while Spotify played the selected local codec.
The actual connected path was:

```text
Known local WAV / ALAC / FLAC
  -> Spotify
  -> process-specific Float32 tap pinned to BlackHole 2ch at 44.1 kHz
  -> filo exact-representation check and FIFO
  -> exclusively owned WALKMAN signed32 output IOProc
  -> bounded copy of the actual output callback bytes for comparison
```

Every receipt reports matching 44.1 kHz stereo input, output, and physical sample rates.
The input is Float32, and both the acquired physical and virtual WALKMAN formats are signed32 with flags 76 and eight bytes per stereo frame.
The exact 24-bit reference integers widen to signed32 by shifting left eight bits.
There are no container padding bits in this 32-valid-bit format; byte equality also checks the eight zero low-order bits introduced by widening.
The expected complete 1,764,000-byte signed32 reference has SHA-256 `8fd04325bfb401bac8d2700c967453319a12e7ead41dde6ee04505e64e118ea5`.
An independent Python calculation read the packed24 WAV, decoded each signed little-endian word, shifted it, and packed signed32 words without using the bridge serializer or Swift comparator.
It produced the same digest.

The comparison covers the actual buffers supplied to the physical-device software callback.
It does not observe USB packets, samples received inside the WALKMAN, analog output, subscription audio, or a streaming master.

## Baseline and procedure

Before these connected trials, WALKMAN was the default output at 192 kHz without an exclusive owner, and BlackHole was at 44.1 kHz with its Internal Fixed clock.
The helper temporarily selected BlackHole as the default route and acquired WALKMAN at the reference rate.
Its cleanup restored the prior route and output format between runs 1 through 8.
For runs 9 through 13, an outer route-only helper held BlackHole as the default between inner CLI executions, while each inner execution still acquired and restored WALKMAN separately.
The outer helper started from the original WALKMAN 192 kHz default baseline, and no warmup playback preceded run 9.
This differs from the earlier [source-only observation](spotify-reference-observation.md), where BlackHole was already the default output and WALKMAN was absent.
Those source-only first selections passed, so the failures below must not be generalized to every first selection in Spotify.

Spotify volume was 1, and normalization, equalizer, mono, crossfade, repeat, shuffle, and autoplay were off in the observed UI.
Gapless and Automix remained on.
The source folder contained only our three synthetic fixtures, and no subscription track was selected.
After the helper reported that capture was armed, the operator used the selected file's Play control and checked its title and empty queue.
The previous selected item before run 1 was ALAC, as verified in the UI.
The selection classifications below record that observed order; they do not identify Spotify's internal decoder or renderer lifecycle.

Runs 1 and 2 requested 30-second windows, and runs 3 through 13 requested 40-second windows.
Failures ended early when the representation fault was detected.
The CLI's `--fixed-clock` option skips clock acquisition and feedback; the baseline Internal Fixed selector was checked independently, rather than inferred from the option name.

## Ordered results

“Production” denotes the unchanged production-source `filo-lab` executable, not the released graphical application.
“Matched muted” and “unmuted” are preserved diagnostic executables built from one isolated source tree with the single tap-policy difference described below.

| Run | Selected codec and predecessor | Executable | Clock following | Recorded output frames | Result and original receipt |
| --- | --- | --- | --- | ---: | --- |
| 1 | ALAC to FLAC, first connected selection | Production | On | 735,232 | [Fault 5](../validation/spotify-exclusive/spotify-connected-flac-reference.json) |
| 2 | FLAC replay | Production | Off | 1,325,568 | [Complete pass](../validation/spotify-exclusive/spotify-connected-flac-fixed-reference.json) |
| 3 | FLAC replay | Production | On | 1,768,448 | [Complete pass](../validation/spotify-exclusive/spotify-connected-flac-follow-repeat-reference.json) |
| 4 | FLAC to WAV | Production | On | 745,984 | [Fault 5](../validation/spotify-exclusive/spotify-connected-wav-reference.json) |
| 5 | WAV replay | Production | On | 1,771,520 | [Complete pass](../validation/spotify-exclusive/spotify-connected-wav-repeat-reference.json) |
| 6 | WAV to ALAC | Production | On | 1,083,392 | [Fault 5](../validation/spotify-exclusive/spotify-connected-alac-reference.json) |
| 7 | ALAC to FLAC | Unmuted | On | 710,144 | [Fault 5](../validation/spotify-exclusive/spotify-connected-unmuted-flac-reference.json) |
| 8 | FLAC to WAV | Matched muted | Off | 539,648 | [Fault 5](../validation/spotify-exclusive/spotify-connected-muted-fixed-wav-reference.json) |
| 9 | WAV to ALAC, held route | Matched muted | Off | 512 | [Fault 5](../validation/spotify-exclusive/spotify-connected-held-fixed-alac-reference.json) |
| 10 | ALAC to FLAC, held route | Matched muted | Off | 1,767,424 | [Complete pass](../validation/spotify-exclusive/spotify-connected-held-fixed-flac-reference.json) |
| 11 | FLAC to ALAC, same held route | Matched muted | Off | 1,766,912 | [Complete pass](../validation/spotify-exclusive/spotify-connected-held-fixed-alac-second-switch-reference.json) |
| 12 | ALAC to WAV, same held route | Matched muted | On | 1,768,448 | [Complete pass](../validation/spotify-exclusive/spotify-connected-held-follow-wav-reference.json) |
| 13 | WAV before Spotify restart, then first ALAC playback, same held route | Matched muted | On | 3,072 | [Fault 5](../validation/spotify-exclusive/spotify-connected-held-fresh-spotify-alac-reference.json) |

The six passing runs compare all 220,500 reference frames and all 1,764,000 raw output bytes.
Their actual and expected aligned SHA-256 values both equal the full signed32 reference hash above.
All six report zero differing bytes, sample words, frames, missing endpoints, or nonzero material outside the reference span.
Their alignment is unambiguous, and the complete reference includes its nonzero first and last frames.

| Passing run | Silent prefix frames | Exact reference frames | Silent suffix frames | Differing bytes |
| --- | ---: | ---: | ---: | ---: |
| 2, FLAC fixed clock | 820,258 | 220,500 | 284,810 | 0 |
| 3, FLAC following | 671,266 | 220,500 | 876,682 | 0 |
| 5, WAV following | 759,842 | 220,500 | 791,178 | 0 |
| 10, FLAC held fixed route | 271,872 | 220,500 | 1,275,052 | 0 |
| 11, ALAC held fixed route | 284,160 | 220,500 | 1,262,252 | 0 |
| 12, WAV held route with following | 730,624 | 220,500 | 817,324 | 0 |

Each failed run reports fault 5, one representation failure, no complete non-silent anchor, zero compared reference frames, and zero compared reference bytes.
The zero mismatch fields in those unaligned comparisons are not successful equality results.
An independent hash check confirms that all recorded output bytes in each failed run are zero.
The bridge checks the entire input callback before publishing it, and the existing receipt does not retain the rejected Float32 input callback.
Consequently, these failures do not reveal an onset envelope, gain curve, interpolation kernel, or other specific source transformation.

All thirteen runs report zero missing or discontinuous input/output timestamps, underflows, overflows, and invalid buffers.
Runs 1 through 8 and 10 through 12 also report zero startup-silence substitutions.
Run 9 reports 231,424 pre-prime startup-silence frames and only 512 recorded post-prime frames, whose 4,096 bytes are all zero.
Run 13 reports 736,256 pre-prime startup-silence frames and only 3,072 recorded post-prime frames, whose 24,576 bytes are all zero.
The bridge's raw-capture storage excludes pre-prime startup silence and callbacks silenced after a fault, so recorded output frames are not a count of the entire failed IOProc timeline.
Delivered frames equal recorded output frames in every receipt.
All thirteen inner CLI sessions report empty cleanup-error arrays.
These counters describe the captured sessions, including the early failures; they do not turn an unaligned or incomplete comparison into a pass.

## Controls and causal limits

The FLAC following, fixed, following sequence contains an initial failure followed by two passes.
Clock following therefore does not invariably fail, and the initial fixed-clock success alone did not establish a clock-related cause.
Run 8 also failed with clock following disabled, so following is not necessary for the observed failure.
A short fixed-clock pass does not establish that unrelated device clocks can run indefinitely without correction.

Run 7 failed with the tap explicitly unmuted, so `mutedWhenTapped` is not necessary for this reproduced failure either.
Apple describes the [tap mute policy](https://developer.apple.com/documentation/coreaudio/catapmutebehavior) as controlling continued delivery to the original hardware while the tap is read.
That contract does not document a captured-sample fade or explain these failures.
The unmuted prototype is a failed diagnostic control, not a proposed product fix.

Within the first eight runs, the observed new-file selections failed and the measured same-file replays passed.
The subsequent held-route FLAC and ALAC new-file selections passed with clock following disabled, and a WAV new-file selection passed with following enabled.
These results show that the initial selection association does not generalize.
The first held-route ALAC trial still failed, so holding the route is not established as a sufficient fix either.
Run order, route transitions, player state, and unobserved internal processing remain potential confounders.
The measurements do not establish that selecting a new file itself causes the change, and they do not identify a decoder, resampler, or CoreAudio component as its source.
The successful ALAC run followed an intervening FLAC selection, rather than a consecutive same-file replay.

For run 13, the operator quit Spotify while it was paused with an empty queue, confirmed that its main process had exited, and relaunched it while the same outer BlackHole route lease remained active.
The freshly launched UI showed Home with no Now Playing item, after which the operator selected ALAC and waited for capture to arm before its first playback.
This run failed the representation check despite the held route.
It adds evidence that startup state matters to this tested path, but does not identify an internal renderer, decoder, gain operation, or tap transition as the cause.

## Executable provenance

| Executable identity | SHA-256 |
| --- | --- |
| Unchanged production-source CLI | `8dcc4b38a73c6b5d847e26e5d8abe7bf2d9dd98c71ee5253dc5452a0ddea0347` |
| Preserved unmuted prototype | `60bfac081dec2f23d47e27ff925738b284034b8915428d62a7d8655a2a78fdcc` |
| Preserved matched muted prototype | `d81a52d3bde8ba6819b00b5251ce31765b408613be8759317f8cfc20805e3b0b` |

The prototype starts from commit `9e5eee4faf2e67f3653a62e35d346784299a2fc6`.
Its [source patch](../validation/spotify-exclusive/unmuted-tap-policy.patch) changes only `description.muteBehavior = .mutedWhenTapped` to `.unmuted` in `ExclusiveRelaySession.swift`.
The [frozen build manifest](../validation/spotify-exclusive/prototype-build-manifest.json) includes both variants' source-input hashes, linked-object hashes, compiler information, and build commands.
Nineteen linked objects match between the paired variants, and only `ExclusiveRelaySession.swift.o` differs.
The representation-check source and object are unchanged.
Both variants used the same compiler and flags, and compilation completed with warnings treated as errors.
The local XCTest attempt was blocked before execution because the configured Command Line Tools could not import XCTest; the manifest records this limitation rather than claiming tests passed.

The manifest's `liveAudioExecuted: false` describes the builder's state before handing the preserved executables to the operator.
The later measured executions are recorded by the ordered receipts and aggregate index.
A subsequent rebuild produced a different executable hash and was not the preserved unmuted artifact used for run 7.
Historical executable hashes identify the measured builds; they are not a promise of reproducible binary bytes across build environments.

The held-route helper has its own [unchanged source snapshot](../validation/spotify-exclusive/spotify-held-route.swift) and [build record](../validation/spotify-exclusive/spotify-held-route-build.json).
It creates no tap or audio callback and uses a separate guarded route lease with a 600-second deadline.
Its shutdown first checks inner recovery and the original WALKMAN format and ownership before restoring the outer default route.
The source must be copied back to `work/spotify-held-route.swift` before using the archived build command, because it locates its temporary recovery files relative to its compiled source path.
Only the absolute project prefix was removed from build-command arguments for publication; the archive records the original build-record hash and this adaptation, while source bytes, input hashes, and executable hash remain unchanged.

## Restoration

Independent live snapshots for runs 2 and 3 confirmed BlackHole as the default route, WALKMAN at 44.1 kHz with an exclusive owner, and matching signed32 physical and virtual formats.
The run 2 clock snapshot showed Internal Fixed, while run 3 showed Internal Adjustable with a noncentral pitch readback.
The initial device, format, and clock snapshots were byte-identical to the independently captured restored snapshots after run 3.
The aggregate index publishes selected nonidentifying properties and snapshot hashes without the private hardware identifiers.
Snapshots initially named as taken during run 1 were actually captured after its early failure and restoration, and are explicitly treated as post-stop evidence.
The run 3 live snapshots were initially named as after snapshots, then correctly relabeled before archival.
The snapshots taken after run 9 show BlackHole still held as the default at 44.1 kHz with its Internal Fixed clock and WALKMAN restored to 192 kHz without an exclusive owner.
They were taken after the early failure and inner cleanup, and therefore do not independently prove the live run 9 exclusive configuration.

Independent run 12 live snapshots confirmed WALKMAN exclusive ownership and signed32 physical and virtual formats at 44.1 kHz, together with BlackHole as the default route and its Internal Adjustable clock.
Its clock snapshot reported pitch 0.5009971 during the run.
After run 13, the outer route holder received `quit`, reported `restored` with no errors, and exited with status 0.
Final independent device-list, WALKMAN-format, and BlackHole-clock snapshots are each byte-identical to the original before snapshots.
WALKMAN is again the default output at 192 kHz without an exclusive owner, and BlackHole is at 44.1 kHz with its Internal Fixed clock.
The outer journal and context were removed, the default connection record was absent, and the operator confirmed that no task audio helper or compiler process remained.

The [UI restoration record](../validation/spotify-exclusive/spotify-connected-ui-restoration.json) reports Spotify paused with an empty queue, autoplay restored on, Show Local Files off, Downloads and My Music sources restored on, and the synthetic source disabled.
The final UI also showed volume 1.
Spotify retains the disabled custom source row.
Normalization, equalizer, crossfade, and mono remain off, while Gapless and Automix remain on, as before these measurements.
No further playback test or processing-preference change is part of this completed experiment series.
