# Using filo

filo requires macOS 14.4 or later and a device with one stereo output stream.
The universal app contains Apple Silicon and Intel executables.
For ordinary listening, use **Format matching** to follow supported source sample rates while the player handles playback.

## First connection

1. Connect your DAC and enable its USB DAC mode if needed.
2. Start filo, select Apple Music or Spotify, then select the DAC.
3. Select Format matching as the audio path.
4. Leave the rate on Automatic for Apple Music, or choose Spotify's labeled 44.1 kHz profile.
5. Click Connect, start playback in the player, and read the source and output cards separately.

Connect changes the Mac's default media output to the chosen device.
It does not change the separate system-alert output.
Another application's explicitly selected output can override the system default for that application.

The **source** card labels automatic evidence from a Music decoder observation or an accessible local Music file.
Manual selections and Spotify's profile use a **target** card because they are requested settings, not detected track metadata.
The **output** card reads the current hardware format.
A 32-bit output container does not imply a 32-bit recording or create extra source detail.
The optional capture line describes the Float32 process tap, not the source's original bit depth.

## Listening settings

Enable lossless quality in your player when your account and content support it.
Review EQ, volume normalization, spatial processing, crossfade, and other effects in the player.
filo neither reads every effect setting nor turns effects off automatically.

For unchanged samples, turn the DAC's listening level down before setting player volume to 100%, then adjust listening level on the DAC.
A matching sample-rate display alone does not prove unchanged samples.
Other apps can still mix into the shared output in Format matching and Direct relay.
In Exclusive preview, only the selected application is forwarded from BlackHole to the DAC.

## Audio paths

**Format matching** manages the output rate and leaves playback on the player's ordinary path.
It is the default, does not capture or relay audio, and requires neither BlackHole nor audio-recording permission.
It follows supported rates both upward and downward; a 192 kHz track does not make 192 kHz the permanent setting for later 44.1 or 48 kHz tracks.
It does not change the player's effects or certify source bit depth, unchanged samples, or what the DAC receives.

**Direct relay**, in the Audio path picker, taps the selected player and suppresses its ordinary output while the tap is active.
It forwards stereo samples without gain, EQ, or sample-rate conversion in filo.
The output device is the aggregate clock, and the configuration requests no drift compensation.
Unsupported formats or stopped callbacks cause the connection to stop.
Disconnect before changing the audio path.

**Exclusive preview** uses an installed BlackHole 2ch as the selected player’s source route and opens the DAC directly with Hog Mode and matching integer formats.
It requires a compatible stereo DAC advertising non-mixable integer formats.
Select a known rate and connect before playback to arm the fixed-rate path; automatic Music detection can still miss the opening of a track.
Known non-unity volume, mute, EQ, or per-track gain prevents the preview from starting.
Unknown settings remain unverified, and there is no end-to-end certification indicator.
The tested Music path changed a known reference before the relay, so this preview currently stops on that path's unrepresentable samples even with the inspected effects disabled.
Use Format matching for ordinary listening while this [source-path issue](research/music-reference-observation.md) remains unresolved.
Read [the preview guide](VERIFIED-OUTPUT.md) for dependencies, verification boundaries, and recovery.

## Automatic format limits

Apple Music does not provide filo with a supported public per-track PCM format API for subscription playback.
The decoder observer uses the timestamps of lossless input-format diagnostics near playback transitions, rather than treating delayed delivery as a new event.
Already assigned observations are not reused for the next track, and conflicting recent rates leave the source unknown.
These safeguards cannot prove that an untagged diagnostic belongs to the playing track rather than a prebuffered track.
Rapid skipping, delayed observations, and prebuffering can still leave the source unknown or make detection arrive after playback begins.
Local file format inspection takes precedence when a readable local file is available.
File lookup takes priority over optional effect checks, and temporary lookup failures are retried at a five-second cadence while the format remains unknown.
This does not guarantee that Music exposes a usable file location or that a short track is detected before it ends.
Lossy formats and some playback paths may not generate a usable observation.

filo keeps the current output rate while the source is unknown.
If it stays unknown, try another track or disconnect, select its known rate manually, and reconnect.
An **Automatic detection unavailable** message persists if the decoder observer fails; reconnect to restart that observer.
Readable local Music files can still supply a rate while streaming detection is unavailable.
If a detected rate is unsupported by the DAC, Format matching keeps playback on the current output rate and shows **Source rate not supported**.
It remains connected and can match a later supported track automatically.
Playback while rates differ may involve conversion in the player or macOS; it is not an exact-rate match.
It cannot undo upstream resampling that already occurred before it detected a change.
Switching the hardware rate can briefly interrupt playback.

Spotify's 44.1 kHz option is a fixed music policy, not lossless detection or per-track verification.
For podcasts, ads, videos, or other content, select a known rate manually if needed.

| Status | Meaning |
| --- | --- |
| Format matched | Hardware rate matches the available local-file or decoder evidence; this is not a fidelity certification. |
| Source format unknown | No usable current evidence; the hardware rate is unchanged. |
| Automatic detection unavailable | The Music decoder observer failed; readable local files remain an alternative. |
| Source rate not supported | The observed rate is unavailable on this output; playback continues at its current rate. |
| Your rate is set | The selected manual rate is applied; automatic detection is off. |
| Spotify profile active | The fixed 44.1 kHz policy is applied; individual tracks are not being detected. |

The [core matching contract and acceptance matrix](CORE-FORMAT-MATCHING.md) distinguish automated behavior checks from hardware and listening validation.

## Permissions

Automation permission allows the playback helper to read the selected player's state, track identity, and volume.
Direct relay and Exclusive preview additionally require macOS system-audio capture permission.
macOS names that privacy section differently across releases, including Screen & System Audio Recording.
Exclusive preview can also trigger a Microphone permission prompt when CoreAudio opens BlackHole's virtual input.
This is a broader macOS permission, although filo selects the virtual device and does not select your physical microphone.
Resolve the system permission prompt before expecting the connection to finish.
If denied, review the relevant permission in System Settings and reconnect filo.
filo does not request administrator access, install a driver, or upload audio.

The download is ad-hoc signed and is not Developer ID notarized.
After an initial blocked launch attempt, macOS may offer Open Anyway in Privacy & Security.
You decide whether to allow it; the app does not change Gatekeeper or other security settings.
Building from source is another option.

## Disconnect, interruptions, and recovery

Disconnect or Quit ends rate management and releases any active relay, then restores only settings filo changed that still match its recorded values.
An already matching rate is not a new rate change that filo owns.
If you or another app changes the output device or rate, filo stops and preserves the intervening change.
This protection also applies before filo's first rate change, and when a requested rate already matches the new external setting.
Sleep releases the connection; reconnect explicitly after waking.
An unplugged device also requires an explicit reconnect.
Device selection and recovery use the device's persistent identity rather than assuming a reused system object number still belongs to the same DAC.

Before modifying hardware settings, filo writes a small recovery record at `~/Library/Application Support/filo/connection.json`.
After an unexpected process exit, reopening filo attempts to restore still-owned settings from that record.
Exclusive preview also stores coupled DAC format and virtual-clock records under `~/Library/Application Support/filo/exclusive-recovery/`.
Recovery coordinates filo processes with a file lock, resolves devices by persistent UID, and preserves external changes.
These atomic records cover process interruption; they are not a power-loss durability guarantee.
It does not automatically reconnect or start playback.
Do not edit the record during an active connection.

## Troubleshooting

| Symptom | Next step |
| --- | --- |
| Source format unknown | Start another lossless Music track or select a known rate manually. |
| Automatic detection unavailable | Reconnect to restart detection, use a readable local Music file, or select a known rate manually. |
| Source rate not supported | Keep listening at the displayed output rate, or use a supported source; automatic matching resumes when supported evidence arrives. |
| Playback access needed | Review Automation permission and confirm the player is running. |
| No audio callbacks | Review audio-capture permission, start playback, or try Format matching. |
| Output changed outside filo | Your change was preserved; reconnect to resume management. |
| Unsupported format | Use a device exposing one stereo stream; relay requires matching Float32 capture/output. |
| Captured samples cannot be represented exactly | Exclusive preview stopped because packing the incoming values would require rounding; use Format matching for ordinary listening. |
| Brief gap during a rate change | This can occur while the DAC changes its hardware rate. |

Copy diagnostics in Connection details gives version, selected source/mode, format observations, and callback counters.
It excludes track titles, file paths, and persistent device identifiers, but includes the output's display name.
Review the text before posting it publicly.
