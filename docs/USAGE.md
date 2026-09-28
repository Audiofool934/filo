# Using filo

[Back to filo](../README.md) · [Install](INSTALL.md) · [Exclusive preview](EXCLUSIVE-PREVIEW.md)

This guide covers everyday use of filo's default **Format matching** path.
If filo is not installed yet, start with the [installation guide](INSTALL.md).

## The card

Click **ƒ** in the menu bar to open filo's card.

- **Top row:** the current mode (**Automatic**, **Spotify profile**, **Manual rate**, or an experimental path), the connection switch, and the **•••** menu.
- **Middle:** the sample rate in kHz and a one-line status.
  The rate is the source's rate when filo knows it, and otherwise your output's current rate.
- **Bottom row:** your player on the left and your output on the right.
  Click either one to change it.

The background scene follows the displayed rate: a CD player through 44.1 kHz, a home studio through 48 kHz, a tube amplifier through 96 kHz, and a reference system above that.
The scenes are decoration, not quality grades.

The **•••** menu opens **Connection details**, **Settings**, and **About filo** inside the card, opens your player, and quits filo.
Click outside the card or press Escape to close it; the connection keeps running while the card is closed.

## Connecting

1. Connect your DAC and turn on its USB DAC mode if it has one.
2. Choose your player and your DAC in the bottom row.
3. Turn on the switch.
4. Play music.

Turning the connection on makes your DAC the Mac's default output.
It does not change the separate output used for system alerts.
An app that has its own output device selected keeps using it.

You can change the player or output while connected; filo restores the previous output and connects the new one.
Turning the switch off, or quitting filo, restores the settings filo changed.

## Reading the status

| Card shows | Meaning |
| --- | --- |
| Ready to match | Disconnected, with an output selected. |
| Choose an output | No output is selected, or the selected one is unplugged. |
| Waiting for music | Connected; the player is not playing. |
| Matched · 24-bit | The DAC's rate matches the source rate filo observed. The bit depth appears when the source depth is known. |
| Manual rate | The rate you chose in Settings is applied; automatic detection is off. |
| Spotify profile | Spotify's fixed 44.1 kHz profile is applied; tracks are not detected individually. |
| Rate matched · depth limited | The rate matches, but the DAC offers no format with enough precision for the source's bit depth. Playback continues. |
| Rate not supported | The source rate is not available on this output. The output stays at its current rate, and matching resumes with the next supported track. |
| Source unknown | filo has no usable format information for the current track, so the output rate is unchanged. Open **Connection details** for the reason. |
| Check connection | filo cannot read the player's current playback information. |
| Connection stopped | The connection ended, for example because the output was unplugged or changed outside filo. **Connection details** explains why. |

While filo works, the status briefly shows **Connecting**, **Matching output**, or **Disconnecting**.

**Connection details** shows the source format and its evidence (**Local file**, **Music decoder**, **Spotify music profile**, or **Manual selection**), the output's actual rate and format, and a sentence describing the current state.

## Settings

Open **••• → Settings** while disconnected.

- **Sample rate:** **Automatic** for Apple Music, **Spotify · 44.1 kHz** for Spotify, or one of the sample rates your output reports.
  Choosing a rate turns off automatic detection until you switch back.
  Selecting a different player resets this to its default.
- **Audio path:** **Format matching** (the default), or the experimental **Direct relay** and **Exclusive preview**.
  See [Audio paths](#audio-paths).

Settings are locked while connected; turn the switch off to change them.

## How automatic detection works

Apple Music does not offer a public way to read the format of the track it is playing.
filo uses two indirect sources of evidence:

1. **Local file.**
   When the current track has a file on your Mac, filo reads the file's header for its rate and bit depth.
   This takes priority, and a failed lookup is retried every five seconds while the format is unknown.
2. **Music decoder.**
   For streamed lossless tracks, Music writes Apple Lossless decoder diagnostics to the system log.
   filo accepts only a fresh diagnostic that appears close to a track change, and treats conflicting rates as unknown.

This works for most lossless listening, with some limits:

- Detection can arrive shortly after a track starts, so its opening may play at the previous rate.
- Rapid skipping and Music's prebuffering of the next track can leave the format unknown.
- Streamed lossy (AAC) tracks produce no decoder evidence, so they stay unknown unless they are local files.
- A short track can end before its format is detected.
- Changing a DAC's hardware rate can briefly interrupt playback.

filo follows rates both up and down; after a 192 kHz track, a 44.1 kHz track brings the DAC back to 44.1 kHz.
While the format is unknown, the output stays at its current rate.
If a track stays unknown, try another track, or disconnect, choose its rate manually, and reconnect.

If the decoder observer itself fails, the details page says **Automatic detection unavailable** until you reconnect.
Local files can still be matched in the meantime.

## Spotify

Spotify does not expose the format of the current track.
filo's Spotify profile sets a fixed 44.1 kHz rate, which suits most music on Spotify.
It is a policy, not detection: it does not show whether Spotify is actually delivering lossless audio.
For podcasts, videos, or other content, choose a rate manually if needed.

## Bit depth and output formats

For a track whose integer bit depth is known, filo chooses among the formats your DAC advertises at the new rate.
It prefers the exact integer depth, then the smallest format with enough precision.
A 32-bit float format holds 24-bit integer audio exactly, so a 32-bit float output does not mean the recording has 32 bits of detail.

If no advertised format has enough precision, the rate still matches and the card shows **Rate matched · depth limited**.
Manual rates, Spotify's profile, floating-point local files, and tracks with unknown depth leave the output's bit depth unchanged.

## Listening settings in your player

filo does not change your player's settings.
If you care about unaltered samples:

- Turn on lossless playback in the player, if your account and content support it.
- Turn off EQ, volume normalization (Sound Check), spatial audio, crossfade, and similar effects.
- Set the player's volume to 100% and control loudness on your DAC or amplifier, lowering the listening level first.

A matching rate on the card does not prove that samples reach your DAC unchanged; your player's processing and other apps' sounds still apply on the default path.

## Audio paths

| Path | What happens | Needs |
| --- | --- | --- |
| **Format matching** (default) | The player plays normally; filo only manages the output's rate and format. | Automation permission. |
| **Direct relay** (experimental) | filo captures the selected player's audio and forwards it to the output without gain, EQ, or rate conversion. | Also system audio recording permission. |
| **Exclusive preview** (experimental) | filo takes exclusive control of the DAC and forwards only the selected player, refusing any sample it cannot pass exactly. | Also BlackHole 2ch, microphone permission, and a compatible DAC. |

Format matching is the path for everyday listening.
In Direct relay, the player's ordinary output is muted while it is captured, and the connection stops if the audio format or callbacks become unusable.
Read the [Exclusive preview guide](EXCLUSIVE-PREVIEW.md) before trying Exclusive preview; on the tested Apple Music path it currently stops rather than plays.

## Permissions

| Permission | Used for | When macOS asks |
| --- | --- | --- |
| Automation (control Music or Spotify) | Reading playback state, the current track, player volume, and for Music, the track's file location. | The first connection with each player. |
| Screen & System Audio Recording | Capturing the player's audio. | Direct relay and Exclusive preview only. |
| Microphone | Opening BlackHole's virtual input; filo never selects a physical microphone. | Exclusive preview only. |

filo reads your player's information without changing your library or playback.
If you deny a permission, the details page explains which one is needed; enable it in **System Settings → Privacy & Security**, then reconnect.
macOS names some of these sections differently across versions.
filo never asks for administrator access and never installs a driver.

## Sleep, unplugging, and outside changes

- **Sleep** disconnects filo; turn the switch on again after waking.
- **Unplugging the DAC** stops the connection; reconnect after plugging it back in.
- **Changing the output elsewhere**, for example in Sound settings or Audio MIDI Setup, stops the connection and keeps your change.
  filo never overwrites a device, rate, or format that you or another app changed while it was connected.

filo identifies devices by their persistent identity, so a reconnected DAC is never confused with another device.

### Recovery after an unexpected exit

Before changing any hardware setting, filo writes a small recovery record to `~/Library/Application Support/filo/connection.json`.
If filo exits unexpectedly, reopening it restores the settings it still owns and removes the record.
It does not reconnect or start playback on its own.
Exclusive preview keeps additional records in `~/Library/Application Support/filo/exclusive-recovery/`; see the [Exclusive preview guide](EXCLUSIVE-PREVIEW.md#recovery).

The records protect against a crash or forced quit, not against power loss.
Do not edit them while filo is connected.

## Troubleshooting

| Symptom | What to do |
| --- | --- |
| Your DAC is not listed | Check the cable and the DAC's USB DAC mode, then reopen the card. |
| Details say filo supports outputs with one stereo stream | filo currently needs an output with exactly one two-channel stream; choose another output. |
| **Source unknown** | Play another lossless track, or disconnect, choose the track's rate in Settings, and reconnect. |
| Details say **Automatic detection unavailable** | Reconnect to restart detection, play a local file, or choose a rate manually. |
| **Rate not supported** | Keep listening at the current rate; matching resumes when a supported track plays. |
| Details ask you to allow filo to read the player | Enable filo for that player in **System Settings → Privacy & Security → Automation**, make sure the player is running, and reconnect. |
| Details say the output or rate changed outside filo | Your change was kept. Turn the switch on again to resume. |
| Details say the output is using an exclusive format | Another app has exclusive control of the DAC; quit it or release the DAC, then reconnect. |
| Details say another filo connection may be active | Quit the other copy of filo, then connect again. |
| Details say a recovery record is retained | Reconnect the missing device; filo finishes restoring it when the device returns. |
| A brief gap when the rate changes | Normal for many DACs while they switch rates. |
| Direct relay reports no audio callbacks | Allow system audio recording for filo, start playback, or use Format matching. |

## Sharing diagnostics

**••• → Connection details → Copy diagnostics** copies a plain-text summary: filo and macOS versions, the selected player and path, the observed formats, and audio callback counters.
It leaves out track titles, file paths, and persistent device identifiers, but includes your output's display name.
Read it before posting it publicly, then include it in a [feedback report](https://github.com/Audiofool934/filo/issues/new/choose).
