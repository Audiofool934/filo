# Spotify direct start with Gapless and Automix off

The single combined-OFF trial still failed exact whole-reference playback and retained the same 512-frame onset as the preceding mode-confirmed experiment.
All 1,024 Float32 words matched both the earlier rejected window and the frozen numerical model, with no parameter refit or offset search.
Disabling Gapless and Automix while Crossfade remained off was insufficient to prevent this transformation in the measured condition.
This joint settings observation does not identify the responsible component or establish the separate effect of any setting.

The measurement occurred on 2026-09-26 at approximately 14:56 Asia/Singapore, corresponding to 06:56 UTC.
Read-only post-trial inspection confirmed Spotify version and bundle build `1.3.0.277`, and macOS `26.6.2`, build `25G83`.
Only the original quiet five-second synthetic local WAV was played during capture.
The [evidence index](../validation/spotify-effects-off/index.json) identifies the unchanged scratch executable, fixture, protocol, timing, and archived source hashes.
No production code, acceptance rule, or released binary changed.

## Setup and coverage

The user supplied a screenshot showing Crossfade, Gapless, and Automix off.
Crossfade was already off in the preceding tests; the joint change was Gapless and Automix from on to off.
The player settings were checked through the UI before capture, along with volume 1, normalization, equalizer, and mono off.
Autoplay was temporarily off, and only the owned canonical fixture source was enabled for the local-file measurement.
The user-selected Crossfade, Gapless, and Automix settings remain off after the test.

Ordinary playback occurred during an initial setup before capture, so that process was paused and replaced with another fresh Spotify process.
The [restart amendment](../validation/spotify-effects-off/restart-amendment.json), [confirmed exit](../validation/spotify-effects-off/final-after-quit.json), and [measurement process record](../validation/spotify-effects-off/measurement-process.json) distinguish that abandoned preparation from the measured source process.
Only one reference capture was performed in this combined-OFF condition.
The mode evidence was the user's earlier confirmation of enabling USB DAC mode during the session, with no new receiver display observation or PCM readback for this trial.
The [mode evidence correction](usb-dac-mode-correction.md) still applies to earlier unknown intervals.

The scratch executable retained `TapAutoStart=false` and SHA-256 `817c8e525c860ecb7a9db5203c0e31941df98d97b1f143e7eed867c510408e0c`, matching the [preceding direct-start trial](spotify-tap-autostart-observation.md).
The canonical WAV remained 220,500 stereo frames at 44.1 kHz and 24-bit precision, with SHA-256 `43728e416e9d6c4b27f03a46aecc604e3353ee1d51dec8b0fcb2037a2f2cd58e`.
The selected callback and physical formats were matching stereo signed32 at 44.1 kHz, flags 76.

The capture was observed armed at `06:56:31.668071 UTC`, and the recorded UI click interval was `06:56:46.439` to `06:56:47.211 UTC`.
The UI then showed the owned reference playing at its beginning, and terminal failure was observed at `06:56:50.228470 UTC`.
The [timing analysis](../validation/spotify-effects-off/timing-analysis.json) places dispatch 14.770929 to 15.542929 seconds after the armed observation and terminal failure at 18.560399 seconds.
These observations are not source-render timestamps, but the retained nonzero rejected callback independently establishes source-related input during the measurement.
The requested 60-second capture ended early on representation failure.

## Measured result

| Observation | Result |
| --- | ---: |
| Strict complete-reference comparison | Failed, with no exact opening anchor. |
| Reference frames and bytes compared | 0 and 0. |
| Representation fault and failure count | Fault 5, one failure. |
| Retained rejected callback | 512 stereo frames, 1,024 Float32 words. |
| Words differing from prior mode-confirmed rejection | 0. |
| Words differing from frozen onset prediction | 0. |
| Words outside the 24-bit integer grid | 1,022. |
| Words outside the 32-bit integer grid | 990. |
| Output frames and bytes captured | 695,296 and 5,562,368. |
| Timing discontinuities, missing timestamps, invalid buffers, underflows, overflows | 0. |
| Helper cleanup errors | 0. |

The [measurement receipt](../validation/spotify-effects-off/combined-off.json) and [independent analysis](../validation/spotify-effects-off/independent-analysis.json) retain the exact counts and raw-word comparisons.
The rejected word sequence again has SHA-256 `5cf6e080227122d714a40e11f39d91fd8629156e1ef585c93a574678b421c99b`.
The first rejected value is `0x35ed8107` at callback frame 1, channel 0, identical to the preceding observation.
The previously fitted model uses a common stereo gain starting at zero, `alpha = Float32(0.002)`, and the same explicitly rounded update already documented in the [onset analysis](spotify-onset-observation.md).
Its fixed reference offset zero is model-dependent alignment, not an exact unprocessed-audio anchor or identification of a private implementation.

The complete output digest is `a11417ab9e0582392fd4125943c4540d2b72581021f3abed7c5363631130f92f`, which the offline audit reproduced from exactly 5,562,368 zero bytes.
The off-grid callback was retained diagnostically before rejection but was not published as changed output samples.
All-zero delivered output is therefore consistent with this measured nonzero rejection and must not be misclassified as an unobserved-playback attempt.
The zero mismatch counters do not indicate a pass because no reference frames were compared.

## Interpretation and artifacts

The same retained onset persists with this combination of user-disabled settings and experimental tap configuration.
This bounds the usefulness of that configuration as a repair; it does not prove the settings never affect other content, transitions, or later samples.
The separate prior trial and this single joint intervention are not a randomized single-factor comparison, and historical renderer state is not fully controlled.
There is no evidence here about samples after the retained 512 frames, arbitrary streaming masters, or Sony receiver equality.
No rounding, gain inversion, omitted opening, automatic replay, or fidelity claim follows from the model agreement.

The [bundle README](../validation/spotify-effects-off/README.md) gives deterministic offline reproduction commands and the exact original watchdog source.
The frozen task-only analyzer handled both a historical full-reference pass and rejection before the new receipt arrived, and its negative controls distinguished changed onset words from exact recurrence.
The initial public adaptation changed repository-root resolution and context wording clarifying that Crossfade was already off.
A later offline consistency fix rejects contradictory failed-receipt flags and comparison counts, including unaligned receipts that claim compared frames; the original measured receipt and numerical onset result remain unchanged.
Original ignored work artifacts are preserved, and no private hardware snapshots, audio files, or executables are published.
The watchdog records normal termination with verification exit code 1, and the [restoration record](../validation/spotify-effects-off/restoration.json) confirms that no task capture process remained.
Spotify was stopped with its synthetic reference selected at 0:00; its prior listening context was not reconstructed.
Autoplay, Downloads, and My Music were restored on, the test source was disabled, and Local Files was restored off.
The user's Crossfade, Gapless, and Automix choices remained off, as did normalization, equalizer, and mono.
WALKMAN was explicitly selected as the final default output according to the user's preference and read back at 192 kHz with Hog Mode released; system alerts remained on the built-in speakers.
BlackHole returned to 44.1 kHz, Internal Fixed, scalar 0.5625, -28 dB, mute off, and inactive.
Formats, clock, and levels matched this experiment's baseline after excluding timestamps, ephemeral identifiers, and default-output fields; the final default media route intentionally differs from the initial built-in-speaker route.
