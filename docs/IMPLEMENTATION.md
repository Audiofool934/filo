# filo implementation record

## 1.1.0-beta.1 implementation record

The next version implements a separate-source exclusive output path and strengthens reference verification and recovery.
Its measured achievement is deterministic sample preservation through the WALKMAN's physical-device output callback in the recorded synthetic experiments.
End-to-end bit-perfect playback through Apple Music or Spotify to the USB receiver remains an unmet validation goal.
The native mode is therefore presented as Exclusive preview, with source processing and continuity uncertainty visible to the user.

### Separate source and exclusive output

`ExclusiveRelaySession` uses two IOProcs: a private process-tap aggregate clocked by BlackHole for capture, and a direct callback on the physical DAC for output.
This separates source capture from the physical device whose exclusive ownership stopped callbacks in the 1.0 same-device experiment.
`ExclusiveDevice` acquires Hog Mode and requires matching advertised non-mixable integer callback and physical formats at the source rate.
Source precision and output container width remain distinct values.
The successful hardware matrix used 16-bit or 24-bit source patterns inside a 32-bit integer output container.

`FiloPCM/Bridge.c` connects the callbacks through preallocated ring storage and atomic state.
Its realtime path performs exact sample representation and serialization without gain, DSP, sample-rate conversion, allocation, locks, logging, or file access.
Non-finite, clipped, or off-grid samples, malformed buffers, timestamp discontinuities, underruns, and overruns latch a fault and silence the failed path instead of silently rounding, dropping, repeating, or replacing samples.
Startup priming preserves queued source frames and records the initial silence separately.
Diagnostic sample and byte capture is bounded and laboratory-only; ordinary app playback does not allocate that capture storage or save music.

`ClockFollower` controls BlackHole's adjustable delivery clock from ring occupancy so it follows the DAC's consumption rate.
It changes virtual callback timing rather than resampling or editing the queued sample values.
`VirtualClock` resolves current selector and pitch controls again after clock-source changes, because BlackHole can destroy and recreate those control objects.
The controller bounds correction and timing, and applied pitch changes are coalesced to at most ten writes per second.
The 120-second hardware experiment is evidence for the tested drift conditions, not an unlimited-duration or universal-device guarantee.

### Known-reference and output-byte evidence

`ReferencePCM` creates quiet deterministic 16-bit or 24-bit stereo WAV fixtures without overwriting an existing file.
It loads bounded supported integer PCM or ALAC references at no more than 24-bit precision, records a SHA-256 file digest, and rejects unsupported or lossy references.
A unique 32-stereo-frame anchor establishes one fixed alignment for a finite reference.
The comparison reports missing prefix and suffix coverage and nonzero material outside the reference separately from sample mismatches, and does not realign, resample, or normalize gain internally.
An exact partial window cannot become a full-reference pass.

`OutputByteVerification` independently constructs expected integer words from the decoded reference and compares them with copied bytes from the actual output callback.
It checks the complete output representation, valid bits, alignment and padding, channel order, sample rate, byte mismatches, frame coverage, and hashes.
It does not reuse the realtime serializer to generate its expected byte stream.
`verify-reference` combines finite-reference coverage with this byte comparison; merely reading an ASBD or observing a clean callback counter cannot produce a whole-reference pass.

The synthetic exclusive matrix and long run passed at the physical callback boundary.
The current Apple Music known-ALAC-over-HTTP attempt failed a pre-relay 24-bit-grid check, so no real-player whole-track success or USB-receiver proof has been achieved.
See [VALIDATION.md](VALIDATION.md) for the separate measured, failed, and pending results.

### Source assessment and lifecycle

`SourceProcessingAssessment` reports readable player volume, mute, equalizer, and track adjustment evidence with freshness and track association checks.
A known active alteration blocks Exclusive preview; missing or stale controls remain unverified rather than becoming a clean-processing claim.
Unreadable Sound Check, enhancement, spatial-audio, transition, normalization, or lossless-selection settings remain explicitly outside that observation.
Format observations and a player's lossless label do not authenticate its decoded sample sequence.

`ConnectionController` serializes segment changes and stops the current callbacks before rearming after a pause, source change, or format transition.
It preserves the distinction between a measured relay segment and continuity from the first source sample through a complete track.
The existing format-matching and shared relay paths remain separate modes.
The beta's final native UI and player lifecycle checks are pending in this implementation record.

### Coupled recovery journal

`ExclusiveRecoveryJournal` groups output rate, physical format, and virtual format, and separately groups the BlackHole selector and readable pitch.
It records original, confirmed, and pending states before hardware writes in private atomic files under a shared process lock.
Devices are resolved by persistent UID and current streams or controls, rather than trusting hardware IDs saved before a reconnect.
The system route and source-rate lease remains the responsibility of `DeviceLease`.
Callbacks stop before output and clock restoration, and the route is restored only after the exclusive hardware state has been released.

Output recovery restores rate first, physical format next, and virtual format last, accounting for the driver's coupled format changes.
A precise original whole-group result is accepted during recovery when restoring the physical format also causes the driver to restore its original floating-point callback format.
Missing devices and other-process ownership defer restoration with the record retained.
An externally changed configuration is preserved as a group instead of partially overwritten.

Exact pitch intent is persisted before every applied adjustment, with bounded update frequency and no realtime file IO.
Atomic replacement covers process interruption; per-adjustment `fsync` and power-loss durability are not promised.
The real synthetic-session SIGKILL experiment restored the rate, both formats, clock selector, and default route and cleared the records.
Fake-hardware cases exercise narrower write/confirmation failure windows and external changes, but do not replace physical hotplug or cross-application testing.

### Remaining beta gates

- A successful CI result for the corrected 1.1.0-beta.1 code is pending.
- Final packaged universal-app and native UI evidence is pending.
- Whole-track known-reference verification through a real music player remains open.
- Independent USB payload or DAC-receiver measurement remains open with the available NW-ZX706 hardware.
- Broader device, OS, physical Intel, hotplug, and sleep/wake validation remains open.

## 1.0 historical implementation record

### Goal

Ship an installable open-source macOS menu bar companion for Apple Music and Spotify, with a GitHub repository and a tested 1.0 release.
Preserve the existing players, automate output sample-rate management, and implement and measure the proposed audio relay before deciding how to expose it.
Report source format, captured format, device format, and verification scope separately.

### Release gates

- Native menu bar app with source and output selection, actual device readback, clear connection state, and actionable errors.
- Automatic format management for Apple Music, with freshness and provenance checks, and an explicitly identified Spotify format policy.
- Investigate and implement process capture, no-DSP transport, and exclusive output with deterministic PCM measurements.
- Lifecycle handling for stop, quit, sleep, source exit, format changes, disconnect, and failed startup; restore only settings still owned by filo.
- No fabricated bit-perfect certification or source bit depth.
- Tests for PCM preservation, malformed formats, switching policy, stale events, errors, and restoration ownership.
- Real device checks on Sony WALKMAN and native UI inspection.
- Reproducible build, install instructions, privacy/permissions documentation, license, CI, versioned release assets, and public repository verification.

### Initial evidence

2026-09-23: existing project contained research documentation only.
Swift 6.3.3 and the macOS 26.5 SDK are usable through the installed Command Line Tools.
Sony WALKMAN is the default output at 192 kHz; system sounds use the built-in speakers.
BlackHole 2ch is available for silent deterministic transport experiments.

### Implementation decisions

Use Swift Package Manager, native macOS UI, direct public CoreAudio APIs, and a small C real-time transport.
Use the MIT license for original implementation; do not incorporate GPL implementation code.
The realtime callback must not allocate, block, access files, or log.
Only synthetic test PCM may be saved by the laboratory tool; the app must not save captured music.
The native implementation, synthetic PCM measurements, player/device checks, and packaged runtime checks are recorded in [VALIDATION.md](VALIDATION.md).
Exclusive output was investigated and failed the callback-delivery test, so it remains a laboratory experiment rather than a claimed app feature.
See [USAGE.md](USAGE.md) for the supported 1.0 behavior and limitations.
The versioned public release is the final delivery gate.
