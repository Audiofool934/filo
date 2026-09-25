# AudioQueue first-start observations

Two fresh AudioQueue sources preserved all 220,500 frames of the unchanged canonical reference at filo's physical-device output callback, including its nonzero opening.
Leaving volume at its default and explicitly assigning unity before the first start both passed.
Neither source played a silent prefix, called `AudioQueuePrime`, or started before capture was armed.
This result uses an experimental tap-start configuration and does not establish Spotify's cause, production first-start behavior, or Sony receiver equality.

The runs occurred on 2026-09-26 in Asia/Singapore, corresponding to 2026-09-25 UTC, with macOS 26.6.2, BlackHole 2ch, and the host-enumerated Sony NW-ZX706 WALKMAN output.
The earlier USB DAC mode assertion was an unverified setup assumption; see the subsequent [mode evidence correction](usb-dac-mode-correction.md).
The [evidence index](../validation/audioqueue-first-start/index.json) identifies the protocol, binaries, linked objects, receipts, independent analysis, and restoration record.
The [reproduction directory](experiments/audioqueue-first-start/README.md) contains the frozen helpers and an offline scratch-build preparation script.
No production source, pass criterion, or released binary changed.

## Why this control differs from the earlier player tests

The earlier [AVAudioPlayer control](player-api-reference-observation.md) used a separate continuously playing silent renderer in the same process to prepare capture.
It could not answer whether a source's first start preserved the opening without that preparation.
The [Spotify observations](spotify-onset-observation.md) showed a changed first callback and a complete same-file repeat; the later [continuous prewarm experiment](spotify-prewarm-observation.md) also passed a complete original after a separate silent file.
Those observations motivated this control, but they are not otherwise matched to it.

The inspected [public API contracts](audioqueue-control-contracts.md) describe aggregate tap autostart waiting for tapped audio when `kAudioAggregateDeviceTapAutoStartKey` is nonzero.
An unstarted child waiting for the parent's GO while the parent waits for aggregate start to return could therefore create a circular dependency.
Before starting either source, the protocol was amended to use a scratch copy of main commit `4e77ac5f65d98359fe8bec4c3c3cb118bae6e822` with that single key changed from `true` to `false`.
This was a preparation choice based on the documented wait contract, not an observed deadlock test of the production setting.
Production retains `true`.

The child explicitly bound its queue to BlackHole and enqueued the original reference once, starting at frame zero, followed by ten seconds of zeros for capture coverage.
The parent found the child's HAL process, created the tap and exclusive relay, waited for relay start to return, recorded metrics, and immediately sent GO.
The child then called `AudioQueueStart` exactly once.
Source buffer-reuse counters were zero at readiness and through the acknowledgement emitted after that call returned.

The aggregate had already captured silence before GO: 18,432 frames in the default arm and 20,992 in the explicit-unity arm.
The explicit-unity arm had also delivered one 512-frame silent output callback before GO; the default arm had delivered none.
These are relay preroll observations while the source queue was unstarted, not a queued source-silence prefix.
Hidden macOS preparation and gain state remain unobserved, so this is not a claim that all Core Audio state was cold.

## Ordered measurements

Each arm used a fresh parent and child process, a new queue, and an independently restored relay session.
The sole intended source-setting difference was zero volume assignments versus one successful `AudioQueueSetParameter` assignment of one before startup.
Every successful volume readback was one and every ramp-time readback was zero seconds in both arms.
Readbacks alone do not prove sample identity or reveal undocumented processing.

| Arm | Complete reference | Captured output frames | Leading capture zeros | Trailing capture zeros |
| --- | --- | --- | --- | --- |
| [Default volume](../validation/audioqueue-first-start/default-first-start.json) | 220,500 frames, exact | 488,448 | 24,576 | 243,372 |
| [Explicit unity](../validation/audioqueue-first-start/unity-first-start.json) | 220,500 frames, exact | 485,888 | 26,112 | 239,276 |

Both comparisons covered 1,764,000 signed32 reference bytes with zero sample, byte, or padding mismatches and no missing opening or ending.
Neither run reported representation failures, invalid buffers, underflows, overflows, timestamp faults, or cleanup errors.
Both exceeded the required two seconds of exact captured zero tail.
The number of queued or reusable postroll frames is not evidence that all ten seconds were rendered; the actual recorded tail is the coverage evidence.

The canonical WAV SHA-256 is `43728e416e9d6c4b27f03a46aecc604e3353ee1d51dec8b0fcb2037a2f2cd58e`.
Both aligned output hashes are `8fd04325bfb401bac8d2700c967453319a12e7ead41dde6ee04505e64e118ea5`.
An [independent offline analysis](../validation/audioqueue-first-start/independent-analysis.json) decoded every canonical integer, reconstructed the signed32 output, and reproduced both complete-capture hashes using the reported zero margins.
All 28 checks per arm passed.
This is a consistency check of the receipts and expected bytes, not a second capture or a receiver-side readback.
The archived [analysis runner](experiments/audioqueue-first-start/analyze-receipts.py) was adapted after the original inline audit and reproduced its complete result apart from a fresh creation timestamp; an altered aligned-hash negative control failed as expected.

Primitive-call timestamps are logged after the API returns.
In particular, `firstStartAfterGO` records Start's return, not its exact invocation instant.
The source control flow and immediately preceding parameter reads place the call after GO.
The false running value in `goAccepted` is cached from readiness, not a fresh post-Start read; later status events separately report running true.

The pair was exploratory, ordered default first and explicit unity second, with one observation per arm.
The recorded protocol required a reverse-order follow-up only for a differential result; neither arm differed here.
There is no failure-rate estimate or general first-start guarantee.

## Preparation and retained failures

An unstarted registration probe preceded the full runs.
Both successful probe receipts found a matching nonzero HAL process even at the observation before queue creation, while output remained inactive.
This establishes observed pre-start visibility on this setup, not that `AudioQueueNewOutput` caused registration or that all fresh queues must be visible.
The first HAL query itself may affect connection state.

An initial probe attempt exited with code 133 before reaching audio or HAL calls because its signal-handler storage could not preserve the null default handler.
The [failure record](../validation/audioqueue-first-start/first-attempt-scaffold-failure.json) retains its provenance separately from playback results.
Nullable handler storage and a dedicated signal-delivery queue fixed the scaffold; three offline signal delivery and restoration checks passed before further live work.
That failure supplies no audio-fidelity evidence.

The final first-start helper compiled with warnings treated as errors and passed ten offline controls, including complete canonical validation, repeated signal handling, altered-reference refusal, and output-overwrite refusal.
The scratch preparation script separately reproduced all 39 pinned package/source/test files and byte-identical provenance, with existing-directory and broken-symlink refusal checks.

## Interpretation and restoration

These two observations show that this prepared AudioQueue path can preserve its complete first reference without explicit source prerendering.
They do not identify Spotify as the owner of the earlier onset or exclude a shared macOS mechanism triggered by different conditions.
A later [Spotify direct-start experiment](spotify-tap-autostart-observation.md), including a repeat after the operator confirmed USB DAC mode enabled, retained the same changed onset with tap autostart disabled.
The setting has not been integrated into production as a repair.
No gain inversion, rounding, trimming, automatic replay, or relaxed acceptance rule follows from this result.

The [restoration record](../validation/audioqueue-first-start/restoration.json) confirms identical before/after device, WALKMAN format, and BlackHole clock snapshots, with BlackHole levels equal after excluding observation time.
The existing Bluetooth default output was retained, WALKMAN returned to 192 kHz with Hog Mode released, and BlackHole returned to 44.1 kHz, Internal Fixed, scalar 0.5, -32 dB, mute off, and inactive.
Both watchdogs recorded normal exit without forced termination; queues were disposed and all task audio processes exited.
Music and Spotify UI or preferences were not changed for this experiment.

The Sony USB receiver, arbitrary subscription master identity, and transparent first-sample control of Music and Spotify remain unverified.
The end-to-end goal remains unmet.
