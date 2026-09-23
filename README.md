# filo

**Your music. A direct connection.**

A small, open-source macOS menu bar companion for Apple Music, Spotify, and your DAC.
Keep your player and let filo manage the output format.

## What it does

- **Apple Music:** follows fresh lossless decoder observations around track changes and reads the format of accessible local files.
- **Spotify:** offers an explicitly labeled 44.1 kHz music profile, plus manual output-rate selection.
- **Your DAC:** reads its actual format, selects supported rates, and restores settings on disconnect or quit when they still belong to filo.
- **Direct relay:** optionally forwards the selected application's stereo PCM through a CoreAudio process tap without gain, EQ, or resampling in filo.
- **Exclusive preview:** routes through an already installed BlackHole 2ch, owns a compatible DAC with Hog Mode, and uses matching non-mixable integer callback and physical formats.
- **Recovery:** stops on device or external routing changes, releases the audio path on sleep, and recovers still-owned settings after an interrupted session.

filo distinguishes a detected source format, a capture format, and a physical output container.
It never labels matching rates as verified end-to-end bit-perfect playback.
Format matching and Direct relay remain shared.
Exclusive preview isolates the DAC output, but source identity and USB receiver delivery still need separate evidence.

## Install

Requires macOS 14.4 or later; the download is universal for Apple Silicon and Intel.
Download the app from [Releases](https://github.com/Audiofool934/filo/releases), unzip it, and move **filo.app** to Applications.

Release builds are ad-hoc signed, not Developer ID notarized.
macOS may require you to use **System Settings → Privacy & Security → Open Anyway** after the first launch attempt.
Review the source or build it yourself if you prefer.
No driver, administrator helper, account, or network service is installed.

## Use

1. Open filo from the menu bar.
2. Select Apple Music or Spotify and an output such as your USB DAC.
3. Choose **Automatic** for Music or the **Spotify · 44.1 kHz** profile, then **Connect**.
4. Start a track in your music app.
5. Choose the audio path in the main configuration; use **Connection details** for evidence limits and diagnostics.

Connecting makes the selected device your Mac's default output in the shared paths.
Exclusive preview instead routes media to BlackHole 2ch and takes direct ownership of the selected DAC.
Other applications routed to BlackHole are not forwarded by the selected-player tap.
System alerts keep their separate existing output selection.
Disconnect restores the previous device and rate only if another app or you have not changed them in the meantime.
After sleep or a device disconnect, reconnect explicitly.

**Format matching** keeps the player's ordinary playback path.
**Direct relay** reads only the selected player and forwards its samples using the output device's clock with tap drift correction requested off.
Neither mode prevents other applications from playing on the same output.

For lossless listening, enable the lossless quality setting in your player and turn off unwanted EQ, normalization, spatial processing, and crossfade.
If you want unchanged PCM, reduce the DAC's listening level before setting the player's volume to 100%, then adjust listening volume on the DAC.
filo does not change player volume or sound effects for you.
See the [setup and troubleshooting guide](docs/USAGE.md).

## What the evidence means

The [validation record](docs/VALIDATION.md) includes exclusive 16-bit and 24-bit tests at 44.1, 48, 96, and 192 kHz, a 120-second run, complete synthetic-reference output-byte equality, and actual process-crash recovery on a Sony WALKMAN.
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
Both HTTP and imported local-file playback produced the same changed samples; see the [reference investigation](docs/research/music-reference-observation.md).
A separate neutral AVAudioPlayer preserved the complete same ALAC through filo's exclusive bridge to the WALKMAN software output callback; see the [controlled player comparison](docs/research/player-api-reference-observation.md).
That laboratory result does not certify Music, Spotify, or samples received inside the DAC.
A separate [Spotify local-file test](docs/research/spotify-reference-observation.md) preserved the complete WAV, ALAC, and FLAC reference at its BlackHole process tap.
That result does not yet connect Spotify to the exclusive DAC output or certify subscription playback.
Read the [exclusive output and verification guide](docs/VERIFIED-OUTPUT.md) before using the preview.

## Build

```sh
git clone https://github.com/Audiofool934/filo.git
cd filo
bash scripts/build.sh
open dist/filo.app
```

For the universal release ZIP and SHA-256 manifest, run `bash scripts/package-release.sh`.

The project uses Swift Package Manager, SwiftUI/AppKit, CoreAudio, and a small C real-time transport.
There are no third-party package dependencies.
Use Xcode 15.3 or later, or a sufficiently recent Command Line Tools installation for building.
Full Xcode with its license accepted is needed for XCTest on installations where the Command Line Tools do not include XCTest.

```sh
swift test
swift build -Xswiftc -warnings-as-errors
```

To select the Command Line Tools explicitly:

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools bash scripts/build.sh
```

## Audio laboratory

The laboratory is separate from normal playback.
It generates quiet, deterministic synthetic stereo PCM and reports exact sample comparisons.
It also verifies a whole known WAV/AIFF/ALAC reference against actual integer output bytes, including padding, prefix/tail coverage, hashes, and callback timestamps.
Use reference capture only for known test material you own, never to record subscription audio.
The app never records music to disk.

```sh
swift build
.build/debug/filo-lab devices
python3 scripts/verify-pcm.py --loopback
.build/debug/filo-lab verify --device 'BlackHole 2ch' --bits 24 --relay --seconds 60
```

The matrix script expects [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole) for silent testing and restores its original sample rate.
To test another device, specify `--device`; synthetic audio will then be sent to that output.
Keep listening levels low.
See [architecture and verification boundaries](docs/ARCHITECTURE.md) before interpreting a passing result.

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

## Contributing

Run the tests and describe the actual macOS version, player, device, and measurement boundary when reporting an audio issue.
Do not claim bit-perfect output from a screenshot of a matching sample rate.
Real-time callback changes must keep allocation, blocking, file access, and logging outside the callback.
Read [CONTRIBUTING.md](CONTRIBUTING.md).

## License and acknowledgments

MIT; see [LICENSE](LICENSE).
The implementation is original and uses public CoreAudio APIs.
[LosslessSwitcher](https://github.com/vincentneo/LosslessSwitcher) and [Choritsu](https://github.com/jcongaku/apple-music-lossless-eq) informed the feasibility research; their source code is not bundled in filo.
The name comes from the Italian word for “thread”.
