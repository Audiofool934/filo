# Spotify direct start with tap autostart disabled

The final fresh-Spotify trial still produced the previously observed 512-frame onset transformation with experimental `TapAutoStart=false`, after the user confirmed enabling USB DAC mode on the Sony NW-ZX706.
All 1,024 retained Float32 words matched the earlier onset and the frozen numerical model exactly, without refitting a coefficient or searching for a new source offset.
Complete-reference verification failed.
Disabling tap autostart is therefore insufficient under this measured condition and is not a production repair.

The three trials occurred on 2026-09-26 in Asia/Singapore, corresponding to 2026-09-25 UTC, with Spotify 1.3.0.277 and macOS 26.6.2.
Only the canonical original synthetic local WAV was selected; subscription audio was not captured.
BlackHole 2ch and the host's WALKMAN output were configured for 44.1 kHz during measurement.
The [evidence index](../validation/spotify-tap-autostart/index.json) records executable, fixture, source, timing, and receipt provenance.

## Ordered conditions and coverage

The scratch executable used the same pinned source substitution as the [AudioQueue first-start experiment](audioqueue-first-start-observation.md): `kAudioAggregateDeviceTapAutoStartKey: true` became `false`.
The recorded executable SHA-256 was `817c8e525c860ecb7a9db5203c0e31941df98d97b1f143e7eed867c510408e0c` for all three trials.
No production source or reference acceptance criterion changed.
The [initial protocol](../validation/spotify-tap-autostart/protocol.json) describes direct selection of the sole canonical reference without a deliberately played silent source or manually inserted queue item.
Player volume was 1; normalization, equalizer, crossfade, mono, autoplay, repeat, and shuffle were off; gapless and Automix remained on.

| Order | Condition | Captured output | Result |
| --- | --- | --- | --- |
| 1 | Initial direct-selection attempt; 30-second request; UI dispatch was not timestamped. | 1,325,056 frames and 10,600,448 bytes, with a whole-capture hash equal to zeros. | No anchor, no rejection snapshot, no representation fault; playback coverage is unproved. [Receipt](../validation/spotify-tap-autostart/false-direct-start.json). |
| 2 | Fresh Spotify process; 60-second request; timestamped direct selection; USB DAC mode interval unknown. | 776,704 frames and 6,213,632 bytes, with a whole-capture hash equal to zeros. | Representation fault 5 with the exact prior 512-frame onset; no complete-reference match. [Receipt](../validation/spotify-tap-autostart/false-fresh-retry.json). |
| 3 | Another fresh Spotify process after the user confirmed enabling USB DAC mode; 60-second request; timestamped direct selection. | 1,247,744 frames and 9,981,952 bytes, with a whole-capture hash equal to zeros. | Representation fault 5 with the same exact 512-frame onset; no complete-reference match. [Receipt](../validation/spotify-tap-autostart/false-mode-on-reference.json). |

The first attempt is a setup/coverage failure, not evidence that the onset disappeared.
Its zero mismatch counts accompany zero compared reference frames.
The output digest covers rendered bytes, while 22,016 accepted input frames remained queued at shutdown; it does not independently establish that every accepted input frame was silent.
Without timestamped playback dispatch, the receipt cannot establish that the intended source played inside its capture window.

The two retries have stronger coverage evidence: timestamped UI dispatch occurred after the observed armed event and before the observed terminal failure, and each retained callback contains nonzero source-related samples.
The second trial's click interval was 17.225938 to 17.492938 seconds after the observed armed event; terminal failure was observed at 20.323082 seconds.
The final trial's click interval was 27.974555 to 28.221555 seconds after the observed armed event; terminal failure was observed at 31.977849 seconds.
These are wrapper and UI observation times, not source-render timestamps.
The configured 60-second windows ended early when representation failure stopped the relay.

The user subsequently clarified that USB DAC mode had not been enabled and then enabled it before the final trial.
The earlier mode intervals remain unknown, including historical measurements cited for numerical comparison.
Enumerated WALKMAN devices, host format readbacks, exclusive ownership, and valid callbacks do not establish the receiver's mode.
Only the final trial has contemporaneous user confirmation of enabled mode, and none includes an independent Sony receiver readback.
The [USB DAC mode correction](usb-dac-mode-correction.md) records the cross-experiment qualification without altering historical raw receipts.

## Exact retained onset comparison

The canonical WAV contains 220,500 stereo frames at 44.1 kHz and 24-bit integer precision, with file SHA-256 `43728e416e9d6c4b27f03a46aecc604e3353ee1d51dec8b0fcb2037a2f2cd58e`.
The [deterministic offline analysis](../validation/spotify-tap-autostart/independent-analysis.json) validates all 441,000 original integer samples against the independent fixture generator before inspecting receipts.
Both retained rejection snapshots cover the complete first rejected 512-frame callback, starting at callback frame zero.
Their interleaved little-endian Float32 word digest is `5cf6e080227122d714a40e11f39d91fd8629156e1ef585c93a574678b421c99b`.
Every retained word equals the [earlier prewarm negative receipt](../validation/spotify-prewarm/onset2-original-after-silence.json), regardless of the earlier unknown USB DAC mode interval.

The previously established numerical model was applied at its frozen reference offset zero:

```text
alpha = Float32(0.002)
gain[0] = 0
predicted[n, channel] = Float32(reference[n, channel] * gain[n])
gain[n + 1] = Float32(gain[n] + alpha * Float32(1 - gain[n]))
```

Each explicit Float32 conversion uses Python `struct`; other multiplication and addition use Python binary64 before the stated final rounding.
Both new windows matched all 1,024 predicted words with zero mismatches.
This reuses the [previously fitted model](spotify-onset-observation.md); it neither refits the new captures nor identifies a unique arithmetic instruction or responsible component.
Offset zero is a model-dependent alignment, and the strict unchanged-audio anchor search found no exact four-frame stereo anchor in either rejection window.

The first rejected word is again `0x35ed8107` at callback frame 1, channel 0.
Its value is `1.76954279140773e-06`, or `14.844000816345215` on the 24-bit integer scale and `3800.064208984375` on the 32-bit integer scale.
Of 1,024 retained words, 1,022 fail exact 24-bit representation and 990 fail exact 32-bit representation; all are finite.
The relay rejected the off-grid callback before publication, so a zero-only output capture is compatible with the independently retained nonzero rejection input.
Both retries reported one representation failure and zero timestamp discontinuities, missing timestamps, invalid buffers, underflows, or overflows.

## Interpretation and reproduction

This observation rules out `TapAutoStart=false` as a sufficient fix for the final measured direct-start condition.
It does not distinguish Spotify processing from CoreAudio processing, identify an undocumented control, establish behavior after frame 511, or prove that USB DAC mode cannot influence other behavior.
The first attempt, process restarts, route history, user mode correction, and non-randomized order prevent treating the series as a clean one-variable causal comparison.
The two successful AudioQueue arms show that their own source path preserved the original under this tap setting; they do not assign the Spotify onset to a component.
No inverse gain, rounding, discarded opening, replay, or new fidelity label is justified.

The [bundle README](../validation/spotify-tap-autostart/README.md) provides offline fixture and analysis commands, recorded live-command provenance, and the distinction between frozen measurement wrappers and the later adapted analyzer.
Offline controls detect a one-bit change and inconsistent offender metadata, and reproduction checks reject corrupted reference input and preserve existing outputs.
The analyzer emits deterministic JSON and does not start players, load a hardware device, or execute a measurement wrapper.

All three watchdogs recorded normal process termination with verification exit code 1, and every measurement receipt has an empty cleanup-error array.
The separate [restoration record](../validation/spotify-tap-autostart/restoration.json) records that task capture processes exited and Spotify was stopped, with Autoplay and its ordinary source toggles restored, the test source disabled, and Local Files off.
The synthetic reference remained selected; the prior playback selection and context were not reconstructed.
WALKMAN was explicitly selected as the final default output at the user's request and read back at 192 kHz with Hog Mode released.
BlackHole returned to 44.1 kHz, Internal Fixed, scalar 0.5625, -28 dB, and mute off, matching this experiment's level baseline.
Formats, clock, and levels matched semantically after excluding timestamps, ephemeral object IDs, and default-route fields; the entire device state was not identical because the original non-test output disconnected and the final default was deliberately changed.
The raw ignored work artifacts remain preserved, while unrelated device identities, audio files, and binaries are excluded from this public bundle.
The software boundary was measured; Sony receiver equality and arbitrary streaming-content fidelity remain unproved.
