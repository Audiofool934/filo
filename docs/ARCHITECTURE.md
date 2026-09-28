# Architecture

[Back to the documentation index](README.md)

filo is a native macOS menu bar app built with Swift Package Manager.
It uses public CoreAudio process-tap and hardware APIs, which set its minimum of macOS 14.4.
It has no driver, background service, network client, or third-party runtime dependency.
It is not an Audio Unit inside Apple Music or Spotify: the player keeps playing, and filo manages the output device around it.

This document describes the current design and where its guarantees stop.
The [validation record](VALIDATION.md) holds the measurements.

## Design principles

- **Keep the player.** filo manages device settings; on the default path it never touches audio.
- **Keep evidence separate.** Source format, tap format, physical output format, and verification results are reported separately, and an unknown stays unknown.
- **Restore only what you still own.** A setting changed by the user or another app is never overwritten.
- **Refuse rather than convert.** An unsupported layout or unrepresentable sample stops the path instead of being silently rounded, resampled, or converted.
- **Keep realtime code minimal.** Audio callbacks are C, with preallocated state and no allocation, locks, logging, file access, or Swift runtime work.
- **Never record music.** Only the laboratory can hold test captures, in memory, of references the user owns.
- **Claim only what was measured,** and name the measurement boundary.

## Package layout

| Target or folder | Role |
| --- | --- |
| `Sources/FiloApp` | The menu bar app: status item, card (`MenuBarPanel`, `FiloView`), selections, permission preflight, and diagnostics (`AppModel`). |
| `Sources/FiloCore` | Everything else in Swift: connection state machine, device access, format detection, device lease, relay sessions, recovery journals, and laboratory verification. |
| `Sources/FiloPCM` | The C realtime code: `Transport.c` for Direct relay and the laboratory, `Bridge.c` for Exclusive preview. |
| `Sources/FiloLab` | `filo-lab`, the command-line audio laboratory bundled next to the app executable. |
| `Tests/FiloCoreTests` | XCTest suites for policies, parsers, lease and journal ownership, PCM representation, and output-byte verification, using fake devices and fixtures. |
| `scripts/` | App and release packaging, release verification, and laboratory harnesses. |
| `Resources/` | `Info.plist`, entitlements, and the four scene images. |

## Processes

A connected filo runs up to four processes:

| Process | Purpose |
| --- | --- |
| `filo` | The menu bar app. An accessory app (`LSUIElement`) with a status item and a borderless, nonactivating 340 × 300 point panel. |
| `filo --player-helper <player>` | A persistent child that runs read-only AppleScript against the selected player on its own main thread and answers each request with one line of JSON. |
| A second player helper (Apple Music only) | Handles slower optional reads: the current track's file location and header, and the player's processing controls. |
| `/usr/bin/log stream` (Apple Music automatic mode only) | Streams Music's Apple Lossless decoder diagnostics, filtered by predicate, into memory. |

The helpers keep the app responsive while macOS shows an Automation prompt or a player is slow.
The primary helper has a three-second response deadline and the supplemental helper ten seconds; a missed deadline stops the reader and shows an error.
Each script also carries its own Apple Event timeout of one or two seconds.
Request generations keep a late reply from a stopped helper from reviving old state.

## Control flow

`ConnectionController` owns one serial queue, `filo.connection`, and every hardware change and source event runs on it.
It publishes an immutable `ConnectionSnapshot` to the main thread and suppresses snapshots that differ only in observation timestamps.

Inputs arrive from:

- Player distributed notifications (`com.apple.Music.playerInfo`, `com.apple.iTunes.playerInfo`, `com.spotify.client.PlaybackStateChanged`), which trigger an immediate player read.
- CoreAudio property listeners for the device list, default output, each device's nominal rate, liveness, streams, and physical formats, coalesced for 100 ms.
- A poll timer while connected: every two seconds for Format matching and every second for the relay paths, with a full hardware refresh at least every ten seconds for drivers that miss notifications.
- A 100 ms clock timer, running only while an Exclusive preview relay is active.
- System sleep, which disconnects, and app termination, which disconnects synchronously.

## Source format evidence

Every source format carries its evidence type, shown in Connection details.

| Evidence | Source | Rules |
| --- | --- | --- |
| Local file | The supplemental helper asks Music for the current track's file location and reads its header with `AVAudioFile`. | Returned with the track's persistent ID so it cannot attach to another track. Retried every five seconds while unknown. Takes precedence over decoder evidence. |
| Music decoder | `DecoderMonitor` parses `ACAppleLosslessDecoder` "Input format" messages from `log stream`. | Only two-channel ALAC with a 16, 20, 24, or 32-bit source and a rate from 8 to 768 kHz. The log event's own timestamp is used, not its delivery time. |
| Spotify music profile | A fixed policy. | Always 44.1 kHz, never described as detection. |
| Manual selection | The user's choice in Settings. | Automatic detection is off. |

`FormatPolicy` associates decoder diagnostics with tracks:

- An observation must be at most three seconds old and fall within the first eight seconds of the current track window.
- A unique rate seen up to two seconds before the playback-state notification can be associated with the new track.
- Conflicting rates in one window make the source unknown for that window.
- An observation already assigned to one track is never reused for the next.

Decoder messages carry no track identity, so this is a bounded heuristic, not authenticated metadata.
It reduces known mistakes but cannot prove the association during rapid skips or prebuffering.

Integer source depth comes from ALAC flags or an integer PCM file's valid bits, never from a decoder's floating-point working format.
Floating-point local files have no integer depth.

## Format matching

```text
Player -> ordinary macOS output mix -> selected DAC
                                        ^
                   filo sets the default output, nominal rate, and physical format
```

`DeviceLease` implements the ownership rules:

1. **Begin.** Resolve the device by persistent UID from a fresh device list, record the original default output, rate, and physical format, write the journal, and make the device the default output.
2. **Apply.** Before every match, including one that needs no write, check that the default output, rate, and physical format still equal what filo last set; otherwise stop and keep the outside change.
   Refuse a device that is in a non-mixable (exclusive) format.
   Journal the new target, write the rate, and read it back.
3. **Choose a physical format.** For a known integer depth, `PhysicalFormatPolicy` considers only advertised shared stereo linear PCM formats at the new rate with enough precision.
   It prefers the exact integer depth, then the smallest adequate precision, then the current representation, then integer over float, then the smaller frame.
   Float32 counts as 24 bits of precision.
   If nothing qualifies, the rate still matches and the snapshot reports a depth limitation.
4. **Unsupported rates.** A rate outside the device's reported ranges is not written; the connection continues and the next supported track matches.
5. **Restore.** On disconnect or quit, restore the rate, then the physical format, then the default output, each only if filo still owns it.
   A write that may have taken effect remains owned for recovery.

The journal is `~/Library/Application Support/filo/connection.json`, written atomically with mode `0600` in a `0700` directory.
It records the owner process ID; on launch and before connecting, a record whose owner is dead is restored, and one whose owner is alive blocks the new connection.
If the device is missing or restoration fails, the record is kept for a later retry.

## Direct relay

```text
Selected player's output on the selected device
    -> private process tap; the player's ordinary output is muted while tapped
    -> private aggregate device with the physical output as its main clock
    -> C callback: stereo Float32 copy
    -> selected physical output
```

The tap and aggregate are private, and the aggregate requests drift compensation off for both the tap and the physical subdevice.
filo reads back the main clock device and requires matching input and output rates in stereo Float32.
Only the tap's input streams are enabled for the callback; any physical input streams on the aggregate are disabled and skipped.
A malformed buffer layout produces silence and an error count, and the control queue then stops the connection.
The connection also stops if no callbacks arrive within three seconds or callbacks stall.

On the tested macOS version, reading the active sub-tap's drift-compensation property returns a bad-object error, so that setting is requested but not independently confirmed.
Digital-loopback measurements supply empirical evidence for the tested configuration, not a guarantee about future macOS implementations.

## Exclusive preview

The 1.0 experiment of holding the DAC in Hog Mode while tapping on the same device stopped callbacks entirely.
Exclusive preview therefore separates capture from output with two independent callbacks:

```text
Selected player -> BlackHole 2ch (the default output while connected)
                -> private process tap in an aggregate clocked by BlackHole    [capture callback]
                -> FiloBridge single-producer, single-consumer queue
                -> DAC held in Hog Mode, non-mixable integer format           [output callback]
```

- **`ExclusiveDevice`** acquires Hog Mode and chooses a little-endian signed 16, 24, or 32-bit non-mixable format that the DAC advertises for both its callback (virtual) and hardware (physical) stream formats at the source rate.
  Source precision and output container width stay separate values; the validated hardware used 16 and 24-bit sources in a 32-bit container.
- **`FiloBridge`** (`Bridge.c`) packs each Float32 sample into the integer format only when it is exactly representable at the declared source precision.
  The queue holds at least two seconds of audio and starts output after a reserve of 150 ms or 2,048 frames, whichever is larger, recording startup silence separately.
  Any fault latches, silences the output, and is reported by number:

  | Fault | Meaning |
  | --- | --- |
  | 1, 2 | Unsupported or changed input or output buffer layout. |
  | 3 | Queue overflow. |
  | 4 | Queue underflow. |
  | 5 | A sample is non-finite, out of range, or off the integer grid. |
  | 6 | Callback sample time deviates from the frame count by more than half a frame, or host time moves backwards. |

- **`ClockFollower`** and **`VirtualClock`** keep the queue near its initial reserve by adjusting BlackHole's adjustable virtual clock instead of resampling.
  The correction is bounded and slew-limited, pitch writes are limited to ten per second, and the session fails if correction stays saturated for 15 seconds.
  Because BlackHole can rebuild its clock controls when the clock source changes, the controls are resolved again after each change.
- **`SourceProcessingAssessment`** blocks known player processing (volume not 100%, mute, EQ, track volume adjustment, track EQ preset) using observations at most three seconds old, or seven seconds for track controls of the same track.
  Unreadable controls are listed as unverified, never assumed off.
- **Segments.** `ExclusivePlaybackPolicy` ends the current relay segment and rearms on pause, track change, process change, format change, ambiguous evidence, or lost player information.
  A fixed manual or Spotify rate can arm before playback, so the opening of a track can be captured; automatic detection can arm only after evidence arrives.
- **Permission preflight.** Before the controller changes any route or touches the DAC, `AppModel` checks Microphone authorization on the main queue.
  An undecided request waits up to 60 seconds and is invalidated by cancellation, sleep, quit, or a change of options.

Sources above 24-bit are refused, because a Float32 tap cannot represent every 32-bit integer value.
The 20-bit case uses the 24-bit grid, on which it is exact.

### Exclusive recovery

`ExclusiveRecoveryJournal` stores records in `~/Library/Application Support/filo/exclusive-recovery/`, one per resource, guarded by an exclusive `flock` on `session.lock`.
It groups the DAC's rate, physical format, and virtual format together, and separately groups BlackHole's clock selector and readable pitch.
Each record holds the original, confirmed, and pending state, and the pending intent is written before every hardware write.
Devices, streams, and controls are resolved again from persistent identity rather than trusting saved object IDs.

Stopping always releases both callbacks first, then restores the DAC group (rate, then physical format, then virtual format, accounting for drivers that change coupled formats together), then the clock, and only then the route lease.
An externally changed group is preserved as a whole rather than partially overwritten.
Missing devices and ownership by another process defer restoration with the record retained.
A callback that fails to release keeps its memory rather than freeing a possibly live context.
Records are replaced atomically, which covers process crashes; there is no per-write `fsync` or power-loss guarantee.
On launch, orphaned exclusive records are recovered before the route lease, so the route never returns to a DAC still held in an exclusive format.

## Privacy and data

- No telemetry, accounts, or network access.
- Player state, track titles, and decoder diagnostics stay in memory.
- Preferences (`blog.audiofool.filo`) hold only the selected player, the selected output's UID, and whether the card has been opened.
- The recovery records contain device identifiers and previous settings, and are removed after restoration or when an outside change ends ownership.
- The only entitlements are Apple Events automation and audio input.
- **Copy diagnostics** leaves out track titles, file paths, and persistent device identifiers, but includes the output's display name.
- Laboratory reference capture is opt-in, in memory, and intended only for reference files the user owns.

## What bit-perfect would require

Strict end-to-end bit-perfect playback requires the original decoded samples, in order, with the same channel order, count, and sample rate, to reach the DAC's input unchanged.
Lossless changes of storage representation and fixed transport latency are allowed.
A 24-bit integer sample is exactly representable in Float32, but that alone does not rule out processing upstream or downstream.

filo cannot obtain an independent reference for a subscription master.
A process tap sits downstream of the player's processing, which may already include volume changes, EQ, or resampling.
On the shared paths, other audio can be mixed after filo's callback.
A readback of the output callback's buffer is not a capture of the USB payload or the DAC's received samples.

## Open problems

- A reliable source-format signal for Apple Music that does not depend on diagnostic logs.
- The tested Apple Music path alters a known reference before it reaches the tap; the responsible component is unknown.
- Spotify's intermittent first-start gain onset, whose cause is unknown.
- Measurement at the USB payload or inside the DAC.
- Coverage of other DACs, physical Intel Macs, older macOS versions, hotplug, and sleep and wake.
