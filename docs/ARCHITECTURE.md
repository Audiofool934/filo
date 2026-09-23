# Architecture and measurement boundaries

filo is a native macOS menu bar app, not an Audio Unit inserted into Apple Music or Spotify.
It uses public CoreAudio process-tap and hardware APIs available from macOS 14.4.
It has no background service, driver, network client, or third-party runtime dependency.

## Control and data paths

`FiloApp` owns the native window, menu bar item, selections, and permission explanations.
`ConnectionController` serializes source events, hardware changes, and lifecycle handling on one control queue.
`DeviceLease` resolves devices by persistent UID and conditionally restores only changes it still owns.
Its atomic local journal supports restoration after an interrupted session.

`PlayerReader` starts a persistent child process from the app executable.
The child runs read-only NSAppleScript requests on its main thread, with a two-second Apple Event timeout, and returns bounded JSON messages.
A slow Music local-file lookup runs after the essential playback response and only once per observed track.
The file lookup returns the track identity with the path to avoid attaching another track's format to cached state.

`DecoderMonitor` reads a narrowly filtered `log stream` process in memory.
`FormatPolicy` accepts lossless input-format observations at most three seconds old during the first eight seconds of a track window.
It can associate a unique rate seen up to two seconds before the playback-state notification.
Conflicting recent rates are treated as unknown.
These rules are a heuristic, not authenticated track metadata.

The direct relay is:

```text
Selected player output on selected device
    -> private process tap, ordinary output muted while tapped
    -> private aggregate, physical output as main clock
    -> C callback, stereo Float32 copy
    -> selected physical output
```

The aggregate explicitly requests tap and physical-subdevice drift compensation off.
The selected main-clock UID and matching input/output sample rates are read back.
The current macOS test host returns a bad-object error for the active sub-tap drift property, so that property is not independently asserted at runtime.
Measured digital-loopback continuity supplies empirical evidence for the tested configuration, not a universal guarantee about future OS implementations.

Only tap input streams are enabled for the relay IOProc.
Physical input streams exposed by an aggregate are disabled and skipped in the buffer layout.
The C callback uses preallocated state, atomic counters, and direct copies or lossless interleaving.
It does not allocate, lock, log, touch files, apply gain, or invoke a sample-rate converter.
Malformed buffer layouts produce silence and increment an error counter; the control queue then stops the connection.

The laboratory's digital-loopback mode separately opens a virtual device's input.
Normal app playback never uses that laboratory input path.

## What bit-perfect would require

Strict end-to-end bit-perfect playback requires the original decoded samples, their order, channel order, count, and sample rate to reach the DAC input unchanged.
Lossless storage-representation changes and fixed transport latency can preserve those samples.
A 24-bit integer sample can be represented exactly in Float32, but that fact does not prove that upstream or downstream processing is absent.

filo does not possess an independent reference for a subscription master.
A process tap is downstream of player processing and can already contain volume changes, EQ, or resampling.
Shared output also allows other audio to be mixed after filo's callback.
An output-container readback is not a capture of the USB payload.

## Laboratory

`filo-lab emit` generates deterministic quiet stereo patterns from `filo_test_sample`.
Each channel has a distinct reference sequence.
`verify` starts a separate emitter, taps it, optionally relays it, and compares a preallocated in-memory capture to the reference.
Only JSON statistics are written by the matrix script.
The GUI never allocates test capture storage or saves music.

The comparator locates a fixed source offset from 32 consecutive exact frames, allowing startup latency and leading silence.
It then compares every remaining recorded frame in order.
It does not normalize gain, resample, delete internal silence, or realign after dropped or repeated samples.
Tests deliberately introduce gain, channel swaps, dropped frames, repeated frames, and silence to check that the comparison fails.

By default, verification measures the process-tap input while the relay is running.
With `--relay --loopback`, it instead measures the final rendered virtual-device input, including filo's output callback and the virtual-device path.
Neither mode measures the physical USB DAC input.
See [VALIDATION.md](VALIDATION.md) for actual results and untested cases.

## Future work

- Reliable source-format identification independent of diagnostic logs.
- Capture/reference experiments for local files decoded by Music itself.
- A working exclusive-output topology that does not starve the source tap.
- Physical digital-output or USB payload comparison against known reference samples.
- Broader OS, Intel hardware, device, hotplug, and sleep/wake testing.

These are explicitly outside the guarantees of 1.0.
