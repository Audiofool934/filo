# Exclusive preview

[Back to the user guide](USAGE.md) · [Architecture](ARCHITECTURE.md) · [Validation](VALIDATION.md)

Exclusive preview is an experimental audio path that takes exclusive control of your DAC and forwards only the selected player's audio to it, refusing any sample it cannot pass on exactly.
It is a research feature.
It does not certify arbitrary Apple Music or Spotify tracks as bit-perfect, and on the tested Apple Music path it currently stops instead of playing.
Use **Format matching** for everyday listening.

## How it works

```text
Selected player -> BlackHole 2ch at the selected rate
                -> private tap of the player's process only
                -> preallocated sample queue
                -> DAC output callback in a matching non-mixable integer format
                -> macOS USB audio driver -> DAC
```

While connected, BlackHole becomes the Mac's default output, and filo holds the DAC in Hog Mode, meaning exclusive access.
The player's audio is tapped from BlackHole, and filo writes it directly to the DAC.
Other apps that use the default output play into BlackHole and are not heard; system alerts keep their own output.

filo chooses a DAC format whose callback and hardware representations are the same non-mixable signed integer format, so macOS performs no float-to-integer conversion at the DAC callback.
Each incoming sample must be exactly representable in that integer format.
filo never rounds, clips, dithers, resamples, or changes gain; a sample that would need any of those stops the connection.
Widening 16-bit or 24-bit audio into a 32-bit integer container preserves every value.

BlackHole and the DAC run on independent clocks.
Instead of resampling, filo gently adjusts BlackHole's adjustable virtual clock so its delivery follows the DAC's consumption.
If the queue runs empty or overflows, or callback timing jumps, the connection stops.
[Architecture](ARCHITECTURE.md#exclusive-preview) describes the mechanism in detail.

## Requirements

- macOS 14.4 or later.
- [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole), installed separately, with its adjustable virtual clock.
  filo does not bundle or install BlackHole, and uses only its documented [virtual clock control](https://github.com/ExistentialAudio/BlackHole/wiki/Adjust-Virtual-Clock).
- A DAC with one stereo output stream that advertises a non-mixable signed integer format at the chosen rate, for both its callback and hardware formats.
- Permissions for Automation, system audio recording, and the Microphone.
  macOS protects BlackHole's virtual input with the Microphone permission; filo never selects a physical microphone.

Only rates supported by both BlackHole and your DAC are offered.
Sources above 24-bit are refused, because a Float32 tap cannot carry every 32-bit integer value exactly.
Hardware validation so far covers a single DAC, the Sony NW-ZX706; other devices may refuse the format or exclusive access.

## Before you connect

1. Lower the listening level on your DAC or amplifier.
2. In the player, set volume to 100% and turn off EQ, Sound Check or volume normalization, spatial audio, crossfade, Automix, and any per-track volume or EQ.
3. In filo, disconnect and open **••• → Settings**.
4. Choose **Audio path → Exclusive preview** and choose your physical DAC as the output.
5. Choose a known **Sample rate** for the music you will play, if you can.

filo reads what each player's scripting interface exposes and refuses to start while it sees known processing:

| Checked and blocking when active | Apple Music | Spotify |
| --- | --- | --- |
| Player volume other than 100% | Yes | Yes |
| Player mute | Yes | Not readable |
| Player equalizer | Yes | Not readable |
| Track volume adjustment or track EQ preset | Yes | Not readable |

Everything else stays **unverified**, never assumed off.
For Apple Music that includes Sound Check, Sound Enhancer, Dolby Atmos, and song transitions; for Spotify, volume normalization, Automix, crossfade, and lossless selection.
Connection details lists the unverified controls.

## Connecting and playing

Turn on the switch before you start playback.

- If macOS has not yet decided the Microphone permission, the card shows **Waiting for microphone permission** and waits up to 60 seconds for your answer before touching any device.
- With a manually chosen rate, the path is **Armed at the selected rate** before playback, so the opening of the track can be captured.
- With automatic detection, the path can arm only after Music's format evidence arrives, which is usually after the track has already started.
- **Exclusive preview active** means integer output is running and samples are flowing.

Pausing, changing track, or changing format ends the current relay segment and starts a new one.
A segment boundary is reported, never silently joined into a claim of continuous sample identity.
There is no gapless or automatic-rate bit-perfect guarantee.

## When it stops

Exclusive preview stops rather than altering audio.

| Message | Cause |
| --- | --- |
| The captured samples cannot be represented exactly in the selected integer format | The audio arriving from the player was already changed, so passing it on would require rounding (bridge fault 5). |
| The DAC ran out of queued audio samples | The source did not keep up with the DAC (fault 4). |
| The source filled the audio buffer faster than the DAC could consume it | The queue overflowed (fault 3). |
| The audio callback timeline changed unexpectedly | A callback's timestamps jumped (fault 6). |
| The audio buffer layout changed or is unsupported | An unexpected buffer layout (faults 1 and 2). |
| A player-setting message, such as setting the volume to 100% | Known player processing is active; change it and reconnect. |

The first message is the one you are most likely to see with Apple Music; see the measurements below.

## What has been measured

| Observation | What it establishes |
| --- | --- |
| Source policy and device rate match | Format configuration only; the source label may be a manual choice or Spotify's policy. |
| Equal virtual and physical integer formats, plus Hog Mode | Configuration and output ownership at the HAL boundary. |
| Synthetic sequence equal at the DAC output callback | The measured relay segment preserves the known samples. |
| Entire lossless reference equal as raw output bytes | The tested player and host path preserve that complete reference under the recorded conditions. |
| Independent USB payload capture or receiver-side bit test | Evidence at the device-bound transport or inside the DAC. Not achieved. |

Measured so far, on one Mac and the NW-ZX706:

- **Synthetic audio** passed exactly at the DAC output callback across 44.1 to 192 kHz at 16 and 24 bits, including a 120-second run and a complete five-second reference.
- **A neutral test player** (AVAudioPlayer) passed a complete ALAC reference through the whole path to the DAC output callback.
- **Apple Music 1.6.6** on macOS 26.6.2 changed the known reference before it reached filo, both from a local file and over HTTP.
  The opening was altered and later samples carried small floating-point differences, so the bridge stopped; see the [Music reference observation](research/music-reference-observation.md).
- **Spotify 1.3.0.277** passed complete local FLAC, WAV, and ALAC references in some runs and failed others at the start of playback.
  In one failed start, a retained 512-frame window matched the original reference multiplied by an exponential gain onset exactly; the responsible component is unidentified.
  See the [connected Spotify observation](research/spotify-exclusive-observation.md) and the [onset investigation](research/spotify-onset-observation.md).

A measurement at the output callback does not observe the driver, the USB wire, or the DAC's receiver.
The Sony's format display reports codec, rate, and depth, not a checksum of the received samples, and no USB payload capture was available; see the [endpoint investigation](research/endpoint-verification.md).
A passing local reference also cannot certify another track, subscription stream, player version, effect setting, or rate transition.
The [validation record](VALIDATION.md) has the full results and the [laboratory guide](LABORATORY.md) shows how to reproduce them.

## Recovery

Disconnecting stops both audio callbacks, releases the DAC, restores its rate and formats and BlackHole's clock, and only then restores the default output.

Before each hardware change, filo records the original, confirmed, and pending state in `~/Library/Application Support/filo/exclusive-recovery/`.
The DAC's rate, physical format, and callback format are restored together as one group, followed by BlackHole's clock source and the media route.
A file lock keeps two filo processes from recovering the same session.
If you or another app change a group while filo is connected, that change is kept.
If a device is missing or restoration fails, the record is kept and retried the next time filo starts.

To retry recovery without opening the app, run the bundled laboratory tool:

```sh
/Applications/filo.app/Contents/MacOS/filo-lab recover
```

The records survive a crash or forced quit, but are not guaranteed to survive power loss.
Do not edit them while connected.
They contain local device identifiers, so redact them before sharing.
