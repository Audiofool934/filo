# Technical notes

These notes document the measurement boundaries, optional laboratory, and permission model.
For ordinary listening, start with the [installation guide](INSTALL.md) and [usage guide](USAGE.md).

## What the evidence means


The [validation record](VALIDATION.md) includes exclusive 16-bit and 24-bit tests at 44.1, 48, 96, and 192 kHz, a 120-second run, complete synthetic-reference output-byte equality, and actual process-crash recovery on a Sony WALKMAN.
The historical 1.0 record separately includes an actual Apple Music 192 → 44.1 kHz queued transition.
The software measurements compare known synthetic PCM against captured samples with no gain normalization or resampling allowed in the comparison.

These results do **not** certify subscription masters, every macOS/player version, or the final USB/DAC input.
Music's decoder diagnostics are not a stable public metadata contract and cannot identify every prebuffered track unambiguously.
Detection can be unavailable or late; without an accepted observation filo shows **Source format unknown**.
An apparently fresh observation can still be misassociated with a prebuffered track.
A hardware rate change can interrupt playback briefly, and the beginning of a track may play at the old rate before detection.

Spotify's profile is a playback policy, not per-track source-format detection.
Podcasts, advertisements, videos, and lossy content may need a different choice.
Matching 44.1 kHz does not establish that Spotify is delivering lossless audio.

The 1.1 beta introduces a separate-source exclusive topology that avoids the callback starvation observed in the 1.0 same-device experiment.
Its C bridge does no resampling, gain, clipping, dithering, or deliberate frame insertion/removal.
A slow controller adjusts BlackHole’s virtual clock cadence to follow the physical DAC.
Invalid representation, buffer exhaustion, or timestamp discontinuity stops the session.
The tested Apple Music path altered a known reference before filo's bridge, even with the inspected effects disabled, so Exclusive preview stopped instead of passing it as exact PCM.
Both HTTP and imported local-file playback produced the same changed samples; see the [reference investigation](research/music-reference-observation.md).
A separate neutral AVAudioPlayer preserved the complete same ALAC through filo's exclusive bridge to the WALKMAN software output callback; see the [controlled player comparison](research/player-api-reference-observation.md).
A later [AudioQueue first-start control](research/audioqueue-first-start-observation.md) preserved the complete reference without source prerendering under an experimental tap configuration; it does not establish Spotify's cause or Sony receiver equality.
That laboratory result does not certify Music, Spotify, or samples received inside the DAC.
A separate [Spotify local-file test](research/spotify-reference-observation.md) preserved the complete WAV, ALAC, and FLAC reference at its BlackHole process tap.
A subsequent [connected Spotify experiment](research/spotify-exclusive-observation.md) preserved complete FLAC, WAV, and ALAC references through the exclusive WALKMAN output callback under recorded conditions.
Other runs failed the strict sample check after output-route changes, including fixed-clock and unmuted-tap controls; holding BlackHole as the default allowed later new-file selections to pass, while the first held-route trial still failed.
This is a conditional local-file result, not reliable arbitrary-track playback, subscription verification, or a measurement inside the DAC.
Beta.3 adds opt-in rejected-input diagnostics; a [first-start measurement](research/spotify-onset-observation.md) exactly matches a 512-frame exponential gain onset, while its same-file repeat preserves the complete reference.
The responsible player or system component remains unidentified, and the verifier continues to reject changed samples.
A [Spotify tap-autostart repeat](research/spotify-tap-autostart-observation.md) retained the same onset with the experimental setting disabled, including after the operator confirmed USB DAC mode enabled.
A subsequent [combined-settings test](research/spotify-effects-off-observation.md) retained the identical opening after Automix and Gapless were disabled, with Crossfade still off; this did not resolve the measured direct-start failure.
Earlier mode labels are qualified by a [setup evidence correction](research/usb-dac-mode-correction.md); the host sample comparisons remain separate from Sony receiver evidence.
Read the [exclusive output and verification guide](VERIFIED-OUTPUT.md) before using the preview.

## Audio laboratory


The laboratory is separate from normal playback.
It generates quiet, deterministic synthetic stereo PCM and reports exact sample comparisons.
It also verifies a whole known WAV/AIFF/ALAC reference against actual integer output bytes, including padding, prefix/tail coverage, hashes, and callback timestamps.
Use reference capture only for known test material you own, never to record subscription audio.
The app never records music to disk.
For reference failures, `verify-reference --inspect-rejection` optionally includes a bounded window of exact input Float32 bit words in its JSON receipt.
This sample-bearing diagnostic is disabled by default and never relaxes the exact comparison or sends rejected samples onward.

```sh
swift build
.build/debug/filo-lab devices
python3 scripts/verify-pcm.py --loopback
.build/debug/filo-lab verify --device 'BlackHole 2ch' --bits 24 --relay --seconds 60
```

The matrix script expects [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole) for silent testing and restores its original sample rate.
To test another device, specify `--device`; synthetic audio will then be sent to that output.
Keep listening levels low.
See [architecture and verification boundaries](ARCHITECTURE.md) before interpreting a passing result.

## Privacy and permissions

filo has no telemetry, accounts, or audio uploads.
Automation permission lets it read playback metadata.
Direct relay and Exclusive preview need macOS system-audio capture permission.
Exclusive preview also checks Microphone permission before opening BlackHole's virtual input or changing the output route.
That OS permission is broad, although filo selects BlackHole rather than a physical microphone.
Only the selected process and output stream are tapped; physical input streams on an aggregate are disabled.
Player titles and source diagnostics stay in memory.
Small local recovery records contain device identifiers and previously owned settings.
Exclusive records use a process lock and record coupled format changes before each write; failed or disconnected recovery is retained for retry.
The records are removed after restoration or when an intervening external change ends ownership.
The optional **Copy diagnostics** action excludes track titles, file paths, and persistent device identifiers.

