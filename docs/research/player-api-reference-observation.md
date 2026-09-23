# AVAudioPlayer known-reference comparison

A neutral AVAudioPlayer reproduced the complete original ALAC reference exactly at the same BlackHole process-tap boundary where Music had changed it.
Enabling rate adjustment while retaining normal speed changed samples in the independent player.
This separates a demonstrated transparent playback configuration from a configuration that looks neutral but is not sample-identical.
It does not identify Music's internal processing or verify delivery to the DAC receiver.
A subsequent single-run measurement also preserved that complete ALAC through filo's exclusive bridge to the actual WALKMAN software output callback.

## Scope and controls

The runs took place on 2026-09-24 local time, on Apple Silicon with macOS 26.6.2, build 25G83.
The ALAC file is the same original five-second, 44.1 kHz, stereo 24-bit synthetic fixture used in the [Music investigation](music-reference-observation.md).
Its SHA-256 is `add662b2c40a791ddd0e406ad638848b58254fc4c4a0220f78e36d4b84510022`.
Before playback, both the parent and child independently decoded it through `ReferencePCM` and checked every sample against `filo_test_sample`.
The child also hashed the exact in-memory file bytes passed to AVAudioPlayer.
No subscription recording, Music library import, or network playback was involved.

BlackHole was configured as the default output at 44.1 kHz before launching the child player.
A separate AVAudioPlayer in that child continuously played an in-memory all-zero WAV with the same channel count, rate, and precision.
That silent stream established an active process so the parent could attach and prime a process-specific capture before sending a one-time `GO` command.
The reference played once, and capture continued for two seconds after successful completion.
The process tap was unmuted and pinned to BlackHole, with `relay: false`; neither the exclusive relay nor physical DAC was opened by this experiment.

The reference player used volume `1`, pan `0`, rate `1`, and zero repeats.
In the first run, `enableRate` was `false`.
In the second run, only the reference player's `enableRate` changed to `true` before preparation; the silent player's controls stayed unchanged.
The ready handshake read back these properties and the player's sample rate and channel count.
Both [baseline](../validation/avplayer-alac-tap.json) and [rate-enabled](../validation/avplayer-alac-rate-enabled-tap.json) receipts include those readbacks, capture hashes, and the temporary helper source hashes.

Apple documents that rate adjustment must be enabled before `prepareToPlay()`, and that `rate = 1` means normal speed.
Those descriptions do not promise that an enabled time/pitch processing path at normal speed preserves every sample.
[enableRate](https://developer.apple.com/documentation/avfaudio/avaudioplayer/enablerate), [rate](https://developer.apple.com/documentation/avfaudio/avaudioplayer/rate).

## Measurements

| Observation | Rate adjustment disabled | Rate adjustment enabled, rate 1 |
| --- | ---: | ---: |
| Captured stereo frames including silence | 342,016 | 343,040 |
| First active capture frame | 29,184 | 29,184 |
| Complete active span, frames | 220,500 | 220,500 |
| Nonzero individual samples | 440,970 | 440,970 |
| Samples outside the 24-bit integer grid | 0 | 49,924 |
| Invalid buffer layouts | 0 | 0 |
| Cleanup errors | 0 | 0 |
| Strict complete-reference comparison | Exact | Failed |

The baseline matched all 220,500 reference frames, including frame zero and the final frame, with zero mismatching samples or integer error.
Its 29,184 leading and 92,332 trailing capture frames were silent.
This was direct equality with the original sample values, without gain fitting, rounding, or resampling.

The enabled-rate capture failed the strict comparator because no exact 32-frame opening anchor matched.
That failure's unaligned coverage fields must not be interpreted as proof that the whole audio was missing.
The active-span observation and the separate offline alignment analysis describe what was captured.

Independent stereo cross-correlation confirmed the same fixed reference offset of frame 29,184 in both API captures.
The [offline analysis record](../validation/player-api-reference-analysis.json) confirms complete first-to-last coverage in both, without extra nonzero material outside the aligned reference.
Its exact padded-reference self-test passed, while seven controls with missing, replaced, inserted, or dropped material correctly failed whole-reference equality.

The enabled-rate run differs from the original in 49,924 of 441,000 sample words.
Its whole-reference error is 0.0001236794 LSB24 RMS, with a maximum of 0.00048828125 LSB24, where LSB24 means one signed 24-bit integer step.
All samples round back to the original 24-bit values in an offline diagnostic, but raw equality still fails and the production bridge does not round them into a pass.
These very small differences do not reproduce Music's substantial opening transformation.
The enabled-rate opening RMS error is 0.0001256902 LSB24, compared with Music's 2,461.43503 LSB24 over the same first 2,048 reference frames.
Its steady-state samples also differ from Music's captured samples.
Enabling rate adjustment therefore demonstrates a different nontransparent configuration, not a reproduction of the Music failure.

After removing only surrounding silence, the baseline Float32 reference span has SHA-256 `f8277734d6e03b38d497bc2397fed81e470cec581a9c564081d7a1db412ae428`.
The enabled-rate span has SHA-256 `8b94a98365792759e003945a4d8cfddfc6eb4298229a92234702dccc854d4918`.
These Float32 hashes describe a different representation from the signed32 bytes used by the physical-output verifier.

## Complete ALAC-to-output callback measurement

A third experiment connected the neutral AVAudioPlayer child to `ExclusiveRelaySession` and the physical WALKMAN output.
It tested the combined chain in one run, rather than inferring a complete path from the earlier separate tap and relay passes.
The parent armed capture before sending `GO`, required successful player completion, preserved two seconds of postroll, and independently compared the actual signed32 bytes written by the output callback with the original reference.
The [measurement receipt](../validation/avplayer-exclusive-reference.json) includes helper source and binary hashes, linked object hashes, format readbacks, timeline, continuity counters, and the complete byte comparison.

| Observation | Result |
| --- | ---: |
| Original ALAC reference | 220,500 stereo frames, 44.1 kHz, 24-bit |
| Callback and physical format | Matching nonmixable stereo signed32, flags 76 |
| Original reference frames compared | 220,500 |
| Original reference bytes compared in signed32 representation | 1,764,000 |
| Mismatching frames, sample words, or bytes | 0 |
| Missing first or last reference frames | 0 |
| Silent prefix | 55,296 frames |
| Silent suffix | 76,972 frames |
| Underflows, overflows, representation failures, or latched faults | 0 |
| Missing or discontinuous capture/output timestamps | 0 |
| Cleanup errors | 0 |

Expected and actual aligned output bytes both have SHA-256 `8fd04325bfb401bac8d2700c967453319a12e7ead41dde6ee04505e64e118ea5`.
The representation widens the original 24-bit integer values exactly into the 32-bit output stream; the reference comparison includes every output bit and the surrounding silence.
The bridge's virtual-clock following remained enabled, and no source sample rounding, gain correction, or sample-rate conversion was added.
The complete run, including restoration, took approximately 12 seconds.

AVAudioPlayer does not expose decoder or source-output callback timestamps to this helper.
The receipt explicitly marks that evidence unavailable and records the successful playback delegate completion separately from the measured relay capture and physical-output timestamps.
The raw-byte comparison establishes the complete original sequence at the software output boundary despite that source timing-observation limit.
It does not observe USB payloads, the Sony receiver, or analog output, and it is not an Apple Music or Spotify streaming test.

## What this establishes

The ALAC file, its decode path in this neutral AVAudioPlayer configuration, and the tested downstream BlackHole process-tap path can preserve the complete reference exactly.
The earlier Music transformation therefore is not an unavoidable property of ALAC playback, Float32 representation, or this tap boundary across all players.
An unknown Music-specific path or process-specific configuration remains to be located.
The comparison does not establish that Music uses AVAudioPlayer or that its processing controls match this harness.

Normal playback speed and unity volume alone are insufficient evidence of sample identity.
The controlled `enableRate` comparison demonstrates that point in this harness; it does not establish the cause of Music's different measurements.
No public control was identified that lets filo disable this internal stage in another application.
The installed Music scripting interface exposes no equivalent `enableRate` setting.

The experiment does not show Apple Music or Spotify subscription masters, an actual USB payload, or samples received by the Sony DAC.
The earlier [complete finite-reference output test](music-reference-observation.md#measured-complete-fixture-relay-test) remains a separate measurement using a direct synthetic emitter.
The third experiment above adds a measured ALAC-decoding-to-output-callback result while retaining the same unmeasured receiver boundary.

## Restoration and artifacts

After each of the three runs, independent device-list, WALKMAN physical/virtual format, and BlackHole clock snapshots were byte-identical to their pre-test snapshots.
WALKMAN remained the default output at 192 kHz after restoration, without a Hog Mode owner, and BlackHole returned to its Internal Fixed clock at 44.1 kHz.
The parent and child exited, and no audio helper remained running.
The synthetic raw captures and temporary source helpers are retained locally under the ignored `work/` directory; they are laboratory artifacts, not a supported player feature.
The baseline source files were preserved before introducing the single-factor control, so their hashes remain reproducible locally.
This research changes no shipped application code or beta.2 binary.
