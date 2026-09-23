# Using filo

filo 1.0 requires macOS 14.4 or later and a device with one stereo output stream.
The universal app contains Apple Silicon and Intel executables.

## First connection

1. Connect your DAC and enable its USB DAC mode if needed.
2. Start filo, select Apple Music or Spotify, then select the DAC.
3. Leave the rate on Automatic for Apple Music, or the labeled 44.1 kHz profile for Spotify.
4. Click Connect and start playback in the player.
5. Read the source and output cards separately.

Connect changes the Mac's default media output to the chosen device.
It does not change the separate system-alert output.
Another application's explicitly selected output can override the system default for that application.

The **source** card reports a Music decoder observation, the format of an accessible local Music file, a Spotify policy, or your manual selection.
The **output** card reads the current hardware format.
A 32-bit output container does not imply a 32-bit recording or create extra source detail.
The optional capture line describes the Float32 process tap, not the source's original bit depth.

## Listening settings

Enable lossless quality in your player when your account and content support it.
Review EQ, volume normalization, spatial processing, crossfade, and other effects in the player.
filo neither reads every effect setting nor turns effects off automatically.

For unchanged samples, turn the DAC's listening level down before setting player volume to 100%, then adjust listening level on the DAC.
A matching sample-rate display alone does not prove unchanged samples.
Other apps can still mix into the shared output.

## Audio paths

**Format matching** manages the output rate and leaves playback on the player's ordinary path.
It is the default and does not start a process tap.

**Direct relay**, in Connection details, taps the selected player and suppresses its ordinary output while the tap is active.
It forwards stereo samples without gain, EQ, or sample-rate conversion in filo.
The output device is the aggregate clock, and the configuration requests no drift compensation.
Unsupported formats or stopped callbacks cause the connection to stop.
Disconnect before changing the audio path.

Hog Mode is not an app option in 1.0.
The laboratory retains an experimental switch, but the tested topology produces no callbacks with the physical output hogged.

## Automatic format limits

Apple Music does not provide filo with a supported public per-track PCM format API for subscription playback.
The decoder observer uses fresh lossless input-format diagnostics near track changes.
Its bounded time window reduces stale observations but cannot prove that a log belongs to the current track rather than a prebuffered track.
The source can be unknown, late, or misassociated in an ambiguous prebuffering sequence.
Local file format inspection takes precedence when a readable local file is available.
Lossy formats and some playback paths may not generate a usable observation.

If the source stays unknown, try the next track or choose its known rate manually.
filo keeps the current output rate while the source is unknown.
It cannot undo upstream resampling that already occurred before it detected a change.
Switching the hardware rate can briefly interrupt playback.

Spotify's 44.1 kHz option is a fixed music policy, not lossless detection or per-track verification.
For podcasts, ads, videos, or other content, select a known rate manually if needed.

## Permissions

Automation permission allows the playback helper to read the selected player's state, track identity, and volume.
Direct relay additionally requires macOS system-audio capture permission.
macOS names that privacy section differently across releases, including Screen & System Audio Recording.
If denied, review the relevant permission in System Settings and reconnect filo.
filo does not request administrator access, install a driver, or upload audio.

The 1.0 download is ad-hoc signed and is not Developer ID notarized.
After an initial blocked launch attempt, macOS may offer Open Anyway in Privacy & Security.
You decide whether to allow it; the app does not change Gatekeeper or other security settings.
Building from source is another option.

## Disconnect, interruptions, and recovery

Disconnect or Quit releases the tap and restores settings only when they still match the values filo last set.
If you or another app changes the output device or rate, filo stops and preserves the intervening change.
Sleep releases the connection; reconnect explicitly after waking.
An unplugged device also requires an explicit reconnect.

Before modifying hardware settings, filo writes a small recovery record at `~/Library/Application Support/filo/connection.json`.
After an unexpected process exit, reopening filo attempts to restore still-owned settings from that record.
It does not automatically reconnect or start playback.
Do not edit the record during an active connection.

## Troubleshooting

| Symptom | Next step |
| --- | --- |
| Source format unknown | Start another lossless Music track or select a known rate manually. |
| Playback access needed | Review Automation permission and confirm the player is running. |
| No audio callbacks | Review audio-capture permission, start playback, or try Format matching. |
| Output changed outside filo | Your change was preserved; reconnect to resume management. |
| Unsupported format | Use a device exposing one stereo stream; relay requires matching Float32 capture/output. |
| Brief gap during a rate change | This can occur while the DAC changes its hardware rate. |

Copy diagnostics in Connection details gives version, selected source/mode, format observations, and callback counters.
It excludes track titles, file paths, and persistent device identifiers, but includes the output's display name.
Review the text before posting it publicly.
