# An open-source macOS audio companion: feasibility and the first validation build

Research date: 2026-09-23.
Target setup: Mac → USB → Sony NW-ZX706, with Apple Music and Spotify as source applications.
This document records the research and design before implementation.
See [ARCHITECTURE.md](../ARCHITECTURE.md) and [VALIDATION.md](../VALIDATION.md) for the subsequent implementation and measurements; the open questions below remain as historical context.

The product goal is to preserve the user's existing player and add a menu bar tool for selecting a source application and DAC, with automatic output-format management.
Strict bit-perfect playback means that the decoded source's valid PCM samples reach the DAC input with the same sample rate, channel order, sample count, and sequence; lossless storage-representation changes and fixed transport latency are allowed.
This definition makes no guarantee about volume control, filtering, or digital-to-analog conversion inside the DAC.
Lossless streaming, native sample rate, exclusive access, and sample equality are distinct properties that require separate verification.

## 1. Available system capabilities

Apple's Core Audio Process Tap example can capture a selected process's output and suppress that process's normal output while reading the tap.
The example uses a private aggregate device with the tap as an input; actual capture requires the user's permission to record system audio.
These capabilities support an audio companion outside the player without first implementing a kernel driver.
They do not promise that tap content equals the source file's native decoded PCM.
[Apple's example](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps)

CoreAudio device Hog Mode provides exclusive access.
Ownership belongs to the process that acquires it; a helper taking over the DAC does not automatically give Music a direct output path and may block Music's normal output.
A relay must verify both capture routing and device ownership.
[Apple's exclusive-access interface](https://developer.apple.com/documentation/coreaudio/audiohardwaredevice/togglehogmode())

The name `CATapDescription.isExclusive` is easy to misinterpret.
It excludes the processes in the `processes` list from capture; it does not mean exclusive access to the DAC.
Device exclusivity must be established and confirmed separately.
[Apple's property definition](https://developer.apple.com/documentation/coreaudio/catapdescription/isexclusive)

MusicKit supports library access, queues, and playback control; the public documentation examined during this research did not provide a raw PCM callback for subscription audio on which to base the design.
The architecture therefore does not depend on obtaining raw decoded samples through MusicKit.
[MusicKit](https://developer.apple.com/musickit/)

## 2. Constraints from first principles

If upstream processing resamples 44.1 kHz content to 48 kHz, converting it back to 44.1 kHz downstream cannot guarantee recovery of the original samples.
The tap's reported format describes its captured output and is not independent evidence of the original content format.
Record source, tap, and DAC formats separately, leaving unknown fields unknown.

One output stream has only one sample rate at a time.
Two sources with different rates cannot be mixed into that stream while each retains its original samples.
The first version manages one music source at a time; it must not silently mix concurrent applications and claim bit-perfect playback.

Two endpoints nominally running at 44.1 kHz do not necessarily share a synchronized clock.
If capture and output run independently, the ring buffer may eventually overflow or underrun; automatic resampling or dropping or inserting samples would violate the strict goal.
The design must verify that capture can follow the same DAC clock, rather than merely disabling drift compensation.
Apple explicitly describes aggregate-device drift compensation as resampling.
[Apple's aggregate-device synchronization guide](https://support.apple.com/en-ng/guide/audio-midi-setup/ams094c7edb4/mac)

Increasing bit depth differs from changing sample rate.
16-bit and 24-bit PCM can be represented losslessly in suitable wider containers; correctly scaled 24-bit PCM can also be represented exactly in Float32.
Gain, EQ, dithering, channel transformations, and sample-rate conversion must nevertheless be ruled out individually; the container format alone cannot establish equality across the whole path.

Switching hardware between tracks with different sample rates may require the clock to relock.
If the new track's format is only available after playback starts, correct first samples, no waiting, no replay, and automatic matching cannot all be guaranteed unconditionally.
The product should make any brief wait or restart explicit and test gapless playback of albums with a consistent sample rate separately.

## 3. Two independently deliverable modes

| Mode | Audio path | What can be promised | Main unknowns |
| --- | --- | --- | --- |
| Format companion | The original player continues to output audio directly | Adjust the DAC to the observed source format and display the match status | Source-format detection reliability and timing at playback start and natural track transitions |
| Audio relay | Single-application tap → transport without DSP → DAC output | Preserve samples within the relay segment that passes comparison tests; measure exclusivity separately | Processing before capture, routing and exclusive-access compatibility, and clock synchronization |

The format companion offers value on its own and remains a useful product scope if relay validation fails.
The relay must pass the experiments below before deciding whether it should become the default mode.
The first version prioritizes a Swift/SwiftUI menu bar interface, CoreAudio device control, and a C/C++ real-time audio core.
Audio callbacks must not allocate memory, access files, write logs, or block.
EQ, music recommendations, library management, and network audio are outside the initial scope.

## 4. Validation tools to build first

Prepare known stereo PCM files at 44.1, 48, 96, and 192 kHz, each in 16-bit and 24-bit versions.
Use deterministic sequences, distinct left/right channel markers, low-bit changes, and boundary values; sine waves alone may miss low-bit or channel errors.

Begin with a controllable test player and capture its output through a tap.
Compare captured samples with reference samples when source and target rates match and when they differ.
Identify and report fixed startup latency, but do not make a comparison pass by resampling, normalizing volume, or deleting errors in the middle.
Record the number of differing samples, maximum integer error, missing frames, repeated frames, channel order, and actual formats.

Then play the same local files in Music.app to test a known-content path through the target application.
A passing local-file result does not establish a passing Apple Music subscription-stream result; keep those conclusions separate.
For Spotify and Apple Music subscription playback, first test actual capture availability, format changes, volume behavior, and lifecycle events; do not treat a commercial track and a local file that may use a different master as the same reference source.

Only add DAC output after capture passes, then test whether capture remains valid after acquiring exclusive access and whether loops, duplicate playback, or silence occur.
Inspect device properties, device clocks, output frame counts, and long-term buffer trends.
Sample comparison before the software output callback proves only the software segment; equality at the actual USB/DAC input requires a digital measurement covering the final output or a DAC bit-test.

| Experiment | Question it must answer |
| --- | --- |
| Matching rates at 16/24-bit | Does capture preserve every valid bit exactly? |
| Different source and device rates | Where does conversion occur, and can it be avoided before playback? |
| Acquiring exclusive DAC access | Do capture and the original application continue to work? |
| Long playback | Is there persistent buffer drift or any frame loss or insertion? |
| Natural 44.1 ↔ 192 kHz track transitions | Does format detection arrive late, and is the track opening lost? |
| Gapless albums at one rate | Are silence, restarts, or repeated rate switches inserted incorrectly? |
| Sleep, hot-plugging, and crashes | Are exclusive access and taps released, and usable output restored? |
| Another application starts producing audio | Does it affect the music source or enter the mix? |

## 5. Initial product behavior

After the user selects a source application and DAC, the menu bar interface shows source and output formats; advanced details explain the format evidence and test boundaries.
Use observable states such as "Format matched," "Source format unknown," "Switching," and "Output disconnected."
Exclusive access or matching formats alone must not produce a "Verified bit-perfect" claim.
Passing results apply to specific system versions, application versions, devices, and tested paths, rather than permanently certifying all subscription content.

Format switching follows explicit state transitions: stop the current transport, release necessary resources, negotiate the format, confirm the actual format and device readiness, then resume transport.
A fixed delay is not evidence that every DAC is ready.
When restoring settings, restore only changes still owned by this tool so that the user's manual device selection during playback is preserved.
If exclusivity fails, the source format is unknown, or the device is unsupported, show that state; do not quietly retain a sample-preservation label after falling back to normal playback.

## 6. Starting points for an open-source implementation

LosslessSwitcher's sample-rate detection and device control are useful research references; the project uses GPL-3.0.
Choritsu uses the MIT license and implements a process-tap relay whose lifecycle handling can inform the research.
Retain the applicable licenses and attribution when reusing code; a derivative based on a GPL project must follow that license.
[LosslessSwitcher](https://github.com/vincentneo/LosslessSwitcher)
[Choritsu](https://github.com/jcongaku/apple-music-lossless-eq)

The Choritsu EQ implementation examined during this research enables sub-tap drift compensation and serves a DSP playback goal.
Removing its EQ calculations would not by itself produce a verified bit-perfect engine.
[Examined implementation](https://github.com/jcongaku/apple-music-lossless-eq/blob/main/Audio/ProcessTapEngine.swift)

If public taps cannot meet the capture and clock requirements for sample preservation, a virtual audio device can be evaluated next.
Apple provides an Audio Server Plug-in example, but a virtual driver cannot recover information already lost before reaching it, so a driver is not the default starting point.
[Apple's virtual audio device example](https://developer.apple.com/documentation/CoreAudio/creating-an-audio-server-driver-plug-in)

Research conclusion: a plugin-like experience, a format companion, and an application-audio relay using public APIs are feasible.
The evidence at this stage does not support a universal end-to-end bit-perfect promise for all Apple Music and Spotify content.
The next engineering task is a reproducible capture and sample-equality experiment; its results determine whether the relay architecture holds.
