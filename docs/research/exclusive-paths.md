# Exclusive relay paths and a sample-preserving bridge

Research date: 2026-09-23.
This document proposes experiments, not a claim that a new topology has passed.
The research was read-only: no device settings, playback, permissions, or installed drivers were changed.

## Recommended direction

Use a separate virtual source device and a directly opened physical output.
Route the player to a virtual device at the verified source rate, capture only that player's output there, and let filo own the physical output with a direct HAL IOProc and Hog Mode.
Use a bounded SPSC ring to cross the two callbacks.
Synchronize the virtual device's clock cadence to the physical device rather than resampling the audio or dropping/repeating frames.
BlackHole already supplies a clock adjustment control suitable for a first experiment on this host.
This removes the obvious conflict in the 1.0 path: the player and filo both depend on the same device that filo then makes exclusive.
It does not by itself solve source-format discovery, player DSP, track-boundary handling, or physical USB validation.

```text
Music or Spotify -> unhogged virtual output at source nominal rate
                 -> process-specific tap on that virtual stream
                 -> private capture aggregate clocked by the virtual device
                 -> SPSC sample ring, no DSP or frame edits
                 -> filo's direct IOProc on the hogged physical DAC

Physical timestamps + ring occupancy -> slow control loop -> virtual clock cadence
```

The physical DAC must not also be an output subdevice of the capture aggregate in this design.
That separation is the experiment's central variable.

## What the existing failure establishes

The checked-in 1.0 validation reports zero callbacks after physical-device Hog Mode in the combined tap/aggregate topology on WALKMAN and BlackHole.
It does not establish that direct physical IO under Hog Mode is broken, because the existing code registers its IOProc on the aggregate, not the physical device.
The existing source selects the physical device as the default output and pins the source tap to that same device before taking Hog Mode.
The source is a separate process, so denial of its ordinary device access is a plausible cause of starvation.
An aggregate's access to a hogged member, or an aggregate clock that never starts, is another plausible cause.
The existing evidence cannot distinguish these causes.

Apple's current tap sample describes taps as capture inputs attached to aggregate devices, with optional muting of the captured process's normal output.
It does not promise that a process denied access to a hogged output will continue rendering into a tap.
`CATapDescription.isExclusive` is an exclusion-list switch for capture, not output exclusivity.
See [Apple's tap sample](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps) and the SDK's `CATapDescription.h`.

## Ranked experiments

| Priority | Experiment | Required observation | Falsification or limit |
| --- | --- | --- | --- |
| 1 | Register filo's IOProc directly on WALKMAN, acquire Hog Mode in the same process, emit a quiet known pattern | Nonzero callback count, continuous output timestamps, owner PID remains filo, actual format equals negotiated format | Zero callbacks refutes this direct-output configuration before any tap or bridge is involved |
| 2 | While that direct output remains active, render a separate known source on BlackHole and capture its process-specific tap through a BlackHole-only aggregate | Both callbacks continue; tap sequence matches source; physical output ownership is unaffected | Missing tap callbacks isolates a capture problem rather than ring/clock behavior |
| 3 | Connect those callbacks through an SPSC ring with a fixed startup reserve, initially without clock adjustment | Frame sequence preserved for a bounded run; queue slope is measured | A passing short run is not indefinite synchronization; monotonic queue drift predicts eventual failure |
| 4 | Enable controlled BlackHole clock adjustment using timestamps and queue occupancy | Bounded occupancy over a long run, no over/underflow, exact sample sequence, adjustment settles without source SRC | Any sample mutation, insertion, deletion, timestamp discontinuity, sustained saturation, or unbounded occupancy refutes the tested controller |
| 5 | Replace the synthetic source with Music playing a known local PCM file from its beginning | Entire known file, including initial/final frames, arrives at the final callback byte-exactly after lossless packing | A matched excerpt or an unknown initial offset cannot prove whole-track delivery |
| 6 | Measure USB payload or a genuine physical digital output against the same reference | Device-bound samples, order, count, and rate match | Callback bytes or HAL format readback alone do not prove the USB receiver boundary |

A bounded additional diagnostic can compare acquiring Hog Mode before versus after starting the old aggregate.
Record both source and aggregate callbacks, device-running state, abnormal-stop notifications, and timestamps before and after acquisition.
A late Hog Mode stall supports a routing/ownership dependency but still does not establish which internal HAL client loses access.
Do not ship an order-dependent workaround without the separate-output and continuity tests.

A second diagnostic can use `AudioDeviceStart(physicalDevice, nil)` solely to start hardware timing, paired with the required `AudioDeviceStop(physicalDevice, nil)`.
The SDK explicitly supports that timing-service use.
This may distinguish an idle clock from source exclusion, but it cannot make a separately owned player eligible for exclusive output.

## Direct physical IO and integer negotiation

The macOS 26.5 SDK distinguishes two independent ASBDs.
`kAudioStreamPropertyVirtualFormat` defines the buffers passed to every IOProc on the owning device.
`kAudioStreamPropertyPhysicalFormat` defines the hardware's transaction format.
The public [virtual-format symbol](https://developer.apple.com/documentation/coreaudio/kaudiostreampropertyvirtualformat) and the local `AudioHardwareBase.h` document that distinction.
A 32-bit physical format does not authorize writing integer bytes into a Float32 callback.

Implement negotiation on a serial control queue as follows.

1. Resolve the target by UID and enumerate output `kAudioDevicePropertyStreams`.
2. Capture original nominal rate, virtual ASBD, physical ASBD, buffer size, Hog Mode owner, and any writable mixing state in the conditional-restoration journal.
3. Enumerate `kAudioStreamPropertyAvailableVirtualFormats` and `kAudioStreamPropertyAvailablePhysicalFormats` as `AudioStreamRangedDescription` arrays, not just advertised nominal rates.
4. Require stereo linear PCM at the requested exact rate, sufficient valid bits, and a completely supported byte layout.
5. Acquire Hog Mode only if the current owner is `-1`, and read it back as filo's PID.
6. Select only an advertised physical ASBD, substituting the requested rate within its advertised range.
7. Set the physical format, wait for its property notification with a bounded timeout, and independently read it back.
8. Re-enumerate virtual formats after the physical change and request a matching advertised integer virtual format if available.
9. Read back virtual and physical ASBDs again, checking rate, format ID, flags, channel count, frame/packet bytes, packet frames, and valid bits.
10. Register `AudioDeviceCreateIOProcID` directly on the physical device in the owning process and start it.
11. Stop on any format, rate, ownership, device-alive, or continuity change instead of silently converting.
12. Stop/destroy IO before restoring only journaled settings whose current values still match filo's last write, then release Hog Mode only if still owned by filo.

The [Hog Mode property](https://developer.apple.com/documentation/coreaudio/kaudiodevicepropertyhogmode) is a toggle according to the SDK: its setter ignores the requested PID value and changes ownership relative to the calling process.
A successful write is not sufficient evidence; read back ownership.
This matters particularly during cleanup, where a blind second write could acquire a free device instead of releasing it.

`kAudioFormatFlagIsNonMixable` is the HAL stream-format flag `0x40`.
The observed WALKMAN physical flags `12` encode signed integer and packed storage, not nonmixability.
Do not synthesize a nonmixable ASBD by adding the flag to an unsupported format.
The legacy `kAudioDevicePropertySupportsMixing` property is deprecated and may be absent or non-settable; inspect it as an optional capability, not a universal switch.
Physical Hog Mode plus a mixable virtual format needs its own exclusion test and does not establish integer identity.

The current [mpv exclusive CoreAudio backend](https://github.com/mpv-player/mpv/blob/59d1dc43b963a03cbaa8198d6c92105b67f86c7c/audio/out/ao_coreaudio_exclusive.c) supplies primary implementation evidence for same-process direct IO, ownership acquisition, optional mixing changes, format readback, and state restoration.
Its physical-format setter waits for asynchronous changes rather than assuming the property setter is an immediate transaction.
This supports the API experiment, not a proof that WALKMAN accepts an integer virtual format.

### Exact packing boundary

For a verified signed `b`-bit source where `b` is 16 or 24, the corresponding Float32 values are exactly representable.
For every captured value `x`, compute `q = double(x) * 2^(b-1)` and require finite `x`, an integral `q`, and `-2^(b-1) <= q < 2^(b-1)`.
Reject values outside that grid instead of rounding, clipping, dithering, or normalizing.
This grid check is necessary for a claimed source depth but does not prove the absence of upstream DSP.

For a signed integer output with `w >= b` valid bits, preserve normalized amplitude using the exact integer scaling `q * 2^(w-b)`.
Then serialize according to the negotiated endianness, container width, valid-bit alignment, and interleaving.
Use unsigned bit operations or bounded 64-bit arithmetic to avoid undefined signed left shifts.
Zero all padding bytes deterministically.
Reject unsupported layouts before starting IO rather than guessing how padding is arranged.

For the observed 32-bit packed little-endian stereo output, a 24-bit source value is multiplied by 256 and emitted as two signed 32-bit words per frame.
A strict test compares those final callback bytes with independently generated expected words.
If the virtual format remains Float32, preserve its exact samples but report the boundary as Float32 submitted to HAL, with downstream integer conversion unverified.
Never label that fallback as an integer byte path.

## Lock-free SPSC bridge API plan

The following names describe original proposed interfaces, not imported source code.

- `filo_bridge_create(config)` allocates one fixed-capacity ring, immutable format metadata, cache-separated counters, and optional preallocated synthetic verification storage before IO begins.
- `filo_bridge_push(inputBuffers, inputTimestamp)` is called by exactly one capture callback and publishes complete frames only.
- `filo_bridge_render(outputBuffers, outputTimestamp)` is called by exactly one physical output callback and consumes complete frames only.
- `filo_bridge_arm()` opens the startup gate only after source rate, ownership, layouts, and initial queue reserve have been verified.
- `filo_bridge_mark_end(totalFrames)` is available for known finite fixtures so the consumer can drain exactly to a genuine end rather than calling the expected end an underrun.
- `filo_bridge_snapshot()` returns atomic counters, occupancy extrema, timestamp observations, gate state, and a latched first-fault code to the control queue.
- `filo_bridge_stop()` follows stopped/destroyed IOProcs; only then may storage be read or freed.

Use monotonic 64-bit producer and consumer indices and a power-of-two capacity.
The producer reads the consumer index with acquire ordering, writes sample storage, and releases its new index.
The consumer mirrors that ordering.
Never reset indices while either callback is running.
Assert lock-free atomics on both target architectures and exercise index wrap logic in tests.
Do not put allocation, locks, Swift/Objective-C calls, file access, HAL setters, or waits in either callback.

A practical first capacity is two seconds at the selected rate, with an initial reserve around 100 to 250 ms.
These are experiment parameters, not proven production tuning.
Sizing must account for the largest observed callback and interruption budget, and memory calculation must be overflow checked.
Use a canonical stereo sample layout internally and one supported integer serializer at the final output boundary.
For a first prototype, a Float32 ring plus exact-grid validation and lossless output packing keeps source comparison straightforward.

If the producer lacks capacity for an entire callback, latch overflow and do not overwrite queued frames.
If the armed consumer lacks a complete requested callback and no valid finite end exists, latch underrun and emit silence while the control queue tears down the connection.
Do not duplicate the last frame, discard old frames, partially conceal a fault, or invoke a resampler.
Once any fault is latched, the connection's continuous bit-perfect claim ends permanently for that session.
Silence is a safe failure behavior, not successful bit-perfect delivery.

Before arming, the output may provide documented startup silence without consuming source frames.
The source must be started only after capture is ready, or a whole-track claim cannot include the missing opening frames.
A queue full of pre-playback device silence requires an explicit start epoch; throwing away arbitrary early data after playback begins is not valid gating.
For known local fixtures, start capture first, configure both rates, begin the source from sample zero, and preserve the full finite sequence.
For a stream already playing when filo connects, claim only an explicitly bounded captured segment, not the whole track.

Maintain separate monotonic source and sink frame counts, callback counts, queued frames, maximum callback length, invalid-layout count, exact-grid failures, overflows, underruns, and timestamp discontinuities.
Read timestamps only when their validity flags permit it.
Provide a safe one-writer snapshot per callback, such as an atomic sequence-number protocol read by the non-real-time control queue, to avoid torn timestamp tuples.
A physically missing callback must be detected using elapsed host time as well as unchanged callback counts.

## Clock feedback without sample edits

[BlackHole's maintainer documentation](https://github.com/ExistentialAudio/BlackHole/wiki/Adjust-Virtual-Clock) explicitly proposes changing the virtual clock to match an output device instead of using aggregate drift compensation.
Its control spans approximately one percent in each direction.
A value of `0.5` represents the center setting; smaller values slow source-clock progression and larger values speed it up.
This changes delivery cadence, not the nominal sample-rate selection.

Inspect controls using `kAudioObjectPropertyControlList` and identify `kAudioClockSourceControlClassID` and `kAudioStereoPanControlClassID` dynamically.
For the selector, enumerate `kAudioSelectorControlPropertyAvailableItems`, translate item names using `kAudioSelectorControlPropertyItemName`, and select `Internal Adjustable` through `kAudioSelectorControlPropertyCurrentItem`.
After the control-list change completes, locate the pitch control and use its Float32 `kAudioStereoPanControlPropertyValue`.
Upstream driver's local object numbers are not stable HAL object IDs and must never be hard-coded.
Do not treat every audio device's pan control as a pitch control; restrict this adapter to an identified compatible BlackHole driver, verified clock-selector item names, and a unique stereo-pan control class.
The current host's controls have unavailable names, so requiring a control named pitch would reject this otherwise discoverable configuration.

The [upstream BlackHole source](https://github.com/ExistentialAudio/BlackHole/blob/5fc575e6b309ff3e855f3127f5ba66a9e4c888c4/BlackHole/BlackHole.c) changes host ticks per frame and returns accumulating sample/host timestamps.
It does not resample its copied audio in that pitch-control implementation.
That implementation detail supports the hypothesis, but CoreAudio and the source player must still be measured while the clock is adjusted.

Run the controller on the serial non-real-time queue at a low frequency, initially a few updates per second.
Estimate actual source/sink frame rates from sufficiently separated valid timestamp pairs, use that estimate as feed-forward, and use smoothed occupancy error to eliminate residual drift.
If the queue is too full, slow the virtual source clock; if it is too empty, speed it up.
Clamp correction and per-update slew conservatively, prevent integral windup, and fault on sustained limit saturation or implausible timestamp estimates.
Do not adjust nominal rates during a session and do not change the physical DAC clock policy merely to stabilize occupancy.

First validate controller direction and bounds using a deliberately small virtual-clock perturbation with a synthetic source.
Record raw occupancy extrema and frame counts, not only a smoothed graph.
Then run long enough for a fixed-clock control experiment to exhibit measurable drift, and show the feedback run avoids that drift while every sample still compares equal.
Short zero-error runs cannot validate the long-term clock strategy.

Journal the virtual device's original clock source, pitch value, rate, and any changed volume/mute state before mutations.
Restore only still-owned values after both IO paths stop.
A hardware removal, clock-control disappearance, external control change, format switch, or ownership loss must close the session and preserve external changes.

## Alternatives and rejected shortcuts

A private capture aggregate containing only the source virtual device and its tap avoids introducing the physical output clock into source capture.
A tap-only aggregate may be simpler but needs an explicit clock/callback experiment; do not assume its timing matches the target DAC.
Apple documents aggregate clock synchronization but not sample identity for arbitrary unsynchronized clocks.
The SDK further notes that setting `kAudioAggregateDevicePropertyClockDevice` enables drift correction for aggregate subdevices, so selecting that property is not a safe shortcut to a no-SRC claim.
See [Apple's aggregate-device description](https://developer.apple.com/documentation/coreaudio/audiohardwareaggregatedevice).

Using a fixed-clock BlackHole plus an arbitrarily large ring only postpones drift failure.
An aggregate with drift compensation enabled normally resolves timing by changing the sample stream, which conflicts with exact sample preservation.
Disabling drift without clock synchronization does not make independent oscillators identical.

A custom original AudioServerPlugIn could eventually expose a virtual output whose timestamps follow the physical sink clock and transfer per-client samples through shared memory.
The SDK's `AudioServerPlugIn.h` defines `GetZeroTimeStamp` and per-client output operations for that approach.
That would add an installed driver, system-level lifecycle and permissions, and substantially more recovery work.
Do not bundle or install a driver merely to make the current experiment convenient.
The existing BlackHole adapter is a narrower way to test the required mechanism before deciding whether filo should own that infrastructure.

A native local-file player controlled entirely by filo has a much smaller proof surface: decode a known local lossless file, set the exact rate before frame zero, and feed a direct exclusive IOProc.
It would not satisfy the original request for transparent Apple Music and Spotify streaming, so it must not substitute for the companion work without an explicit product decision.

## Evidence and licensing provenance

- Apple documentation and local macOS 26.5 SDK headers were read for API contracts; no substantial Apple sample code was copied.
- BlackHole source and its maintainer wiki were inspected for observable control semantics and timestamp behavior.
  Its current [license file](https://github.com/ExistentialAudio/BlackHole/blob/master/LICENSE) states GPLv3 for source and separate restrictions for official compiled installers and branding.
  This document proposes interoperability with an existing installed driver, not copying, linking, bundling, or relicensing that implementation.
- mpv's inspected exclusive backend declares LGPL 2.1 or later in the file header.
  It was used as evidence for API ordering only; no implementation was copied into filo's MIT code.
- [AudioCap](https://github.com/insidegui/AudioCap) is BSD 2-Clause and was inspected as an additional process-tap topology reference.
  Its sample enables tap drift compensation, so it is not itself a bit-perfect proof or an exclusive-output solution.
- filo's own 1.0 [architecture](../ARCHITECTURE.md) and [validation](../VALIDATION.md) establish the baseline and its existing failure boundaries.

The deliverable from this research is a falsifiable topology and implementation plan.
It is not evidence that subscription masters are available for reference comparison, that Music can be forced to expose pre-DSP PCM, or that USB-bound bytes have already been observed.
