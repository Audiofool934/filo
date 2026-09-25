# Spotify silence and continuous prewarm observations

Measured on 2026-09-25 with Spotify 1.3.0.277, macOS 26.6.2, BlackHole 2ch, and the host-enumerated Sony NW-ZX706 WALKMAN output.
The earlier USB DAC mode assertion was a setup assumption; see the later [mode evidence correction](usb-dac-mode-correction.md), whose affected earlier interval is unknown.
One continuous sequence of a silent local file followed by the manually queued canonical reference preserved every original reference sample at filo's physical-device output callback.
An intervening independently prepared direct start still failed with the previously measured onset signature.
This establishes a useful experimental condition, not a reliable automatic workaround or receiver-level bit-perfect playback.

The [evidence index](../validation/spotify-prewarm/index.json) identifies the unchanged beta.3 executable, commands, fixtures, run order, restoration record, and artifact hashes.
No production code or acceptance criteria changed for these experiments.
Only original synthetic audio was played and measured.

## Ordered measurements

Each trial independently prepared and restored an exclusive WALKMAN connection through BlackHole.
The third trial kept that one connection alive across both local files.
Player volume was 1; normalization, EQ, crossfade, and mono were off; gapless and Automix remained on.
Autoplay was temporarily off, Downloads and My Music were excluded, and only the synthetic fixture folder was enabled.
Repeat and shuffle were off.

| Order | Condition | Observed result |
| --- | --- | --- |
| 1 | Newly select a five-second WAV containing one second of zeros followed by the first four seconds of the canonical signal. | The complete 176,400-frame active sequence matched exactly; the comparator also matched its zero prefix within capture silence. [Receipt](../validation/spotify-prewarm/onset2-silence-first.json). |
| 2 | Tear down, prepare a fresh relay, and directly select the unchanged five-second canonical WAV. | Representation fault 5; the retained 512-frame callback was bit-for-bit identical to the previously rejected onset. [Receipt](../validation/spotify-prewarm/onset2-original-after-silence.json). |
| 3 | With only the canonical WAV manually queued, select a separate five-second all-zero WAV and retain the same relay across the transition. | All 220,500 original frames and 1,764,000 signed32 bytes matched, including the non-silent opening; no extra nonzero material appeared outside the reference. [Receipt](../validation/spotify-prewarm/onset2-continuous-zero-warmup.json). |

The first two capture requests were 40 seconds; the third was 70 seconds.
The [protocol](../validation/spotify-prewarm/onset2-protocol.json) was recorded during the first capture and extended for the exploratory third condition; it was not a fully preregistered experiment.
Run order was not randomized and there is only one observation per condition here.
Warmup playback, a queued transition, relay continuity, playback history, gapless, and Automix were not independently isolated.

## What the samples establish

The original canonical file has SHA-256 `43728e416e9d6c4b27f03a46aecc604e3353ee1d51dec8b0fcb2037a2f2cd58e` and contains 220,500 stereo frames at 44.1 kHz with 24-bit integer precision.
The third run's aligned signed32 output hash is `8fd04325bfb401bac8d2700c967453319a12e7ead41dde6ee04505e64e118ea5`.
It reported zero sample, byte, and padding mismatches, representation failures, buffer faults, underflows, overflows, timestamp errors, or cleanup errors.
Independent offline encoding of the canonical integers reproduced that hash.
Reconstructing the entire expected capture from the canonical sequence and reported zero margins reproduced the complete capture hash `021d9d451022be54da3a62c7a5fb5fc5136cd58bcd5310502e094f72ce41e2a7`.
The offline check uses the recorded receipt and expected samples; it is not a second capture or an independent readback from the DAC.

The silent-prefix fixture deliberately contains only four seconds of the original signal.
Its pass therefore does not cover the original final second.
Zero samples cannot distinguish source silence from capture preroll, transport padding, or gain applied to silence.
Neither the first run's 44,100 leading zero frames nor the warmup file's 220,500 zero frames have independently established source timing or delivery provenance.
The third run's full non-silent reference is the meaningful improvement over the silent-prefix control.

The second run delivered only silence before rejection, and zero comparison counts do not constitute a successful reference match.
Its 1,024 rejected Float32 words have SHA-256 `5cf6e080227122d714a40e11f39d91fd8629156e1ef585c93a574678b421c99b`, identical to the beta.3 first-start observation.
They also match the previously fitted common-gain model without refitting its coefficient.
More than 22 seconds of output silence preceded the rejected callback, so simply leaving the relay armed was insufficient in this run.
The prior [onset model](spotify-onset-observation.md) still describes only a 512-frame window and does not identify the responsible component or its later behavior.

The queue was observed empty before adding the one canonical item and empty after the experiment.
The UI confirmed the zero warmup starting; no separate intermediate screenshot established the queued canonical title during playback.
Its complete measured sample sequence establishes that the original reference reached the output callback once.
The [combined offline checks](../validation/spotify-prewarm/onset2-offline-controls.json) preserve these distinctions and the frame accounting.

## Reproduction artifacts

The [fixture generator](../validation/spotify-prewarm/make-onset-fixtures.py) independently validates the canonical file hash and all 441,000 integer samples before generating either derived WAV.
It refuses an existing output directory and reproduces both measured fixture files byte-for-byte.
Seven offline controls cover golden output, overwrite refusal, corrupted/truncated input, and malformed format headers.
The fixture manifests record their construction and interpretation limits.

From the repository root, use fresh output paths:

```sh
dist/filo.app/Contents/MacOS/filo-lab fixture \
  --file work/prewarm-reference.wav --hz 44100 --bits 24 --seconds 5
python3 docs/validation/spotify-prewarm/make-onset-fixtures.py \
  --reference work/prewarm-reference.wav --output-dir work/prewarm-fixtures
python3 docs/validation/spotify-onset/analyze-rejected-reference.py \
  --reference work/prewarm-reference.wav \
  --report docs/validation/spotify-prewarm/onset2-original-after-silence.json \
  --output work/prewarm-rejection-analysis.json
```

These commands only prepare and analyze files.
The live command in the evidence index requires an explicitly prepared player sequence and changes audio routing while it runs.
The all-zero file is an experimental warmup, never a reference whose apparent pass certifies fidelity.

## Integration boundary and cleanup

The bounded [primary-source search](spotify-onset-primary-sources.md) found no documented match for the exact onset recurrence and no supported smoothing-disable control.
The [integration audit](spotify-prewarm-integration-feasibility.md) found no supported before-first-sample interception, hidden gain-ready signal, or atomic preservation and restoration of an arbitrary Spotify queue.
filo already permits continuous playing track changes without restarting the explicit-rate relay, but that does not establish Spotify's source processing state.
The defensible next experiment is a deliberately prepared sequence, not transparent insertion of a silent track into an arbitrary listening session.
This result does not justify rounding, gain inversion, omitting an opening, automatic replay, or a new verified label for arbitrary content.

All three audio sessions exited and reported empty cleanup-error arrays.
Spotify Autoplay, Downloads, and My Music were restored on; the own fixture source was disabled and Local Files restored off.
Spotify remained paused, its queue was empty, and its other processing settings were preserved.
Read-only final inspection confirmed WALKMAN at its original 192 kHz with Hog Mode released, and BlackHole at 44.1 kHz, Internal Fixed, scalar 0.5, -32 dB, mute off.
Current and supported WALKMAN formats and BlackHole clock controls matched after excluding changed ephemeral HAL object IDs.
A new Bluetooth default output appeared between initial and final snapshots; its cause and exact timing were not established.
That external final selection was preserved instead of forcing the older built-in-speaker default.
The [sanitized restoration record](../validation/spotify-prewarm/restoration.json) explicitly records that the whole device snapshot is not identical.

The Sony USB receiver and subscription masters remain unmeasured.
This research improves understanding of a conditional software-path pass while the end-to-end objective remains unmet.

A subsequent [AudioQueue first-start control](audioqueue-first-start-observation.md) preserved the complete original in both default-volume and explicit-unity arms without a source-silence prefix.
It used experimental tap autostart disabled and observed aggregate preroll before GO, so it does not attribute this Spotify onset or establish a production repair.
