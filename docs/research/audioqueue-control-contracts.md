# AudioQueue default-versus-explicit-unity control contracts

Inspected on 2026-09-25 without invoking AudioQueue, HAL, UI, or playback APIs.
Local references use the Command Line Tools macOS 26.5 SDK at `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`.
`AudioQueue.h` is under `System/Library/Frameworks/AudioToolbox.framework/Versions/A/Headers`, while `AudioHardware.h` and `CATapDescription.h` are under the corresponding CoreAudio framework headers.
These contracts do not expose the internal implementation of the measured macOS build.

## Public contracts

| API or property | Public contract | Experimental consequence |
| --- | --- | --- |
| [AudioQueueNewOutput](https://developer.apple.com/documentation/audiotoolbox/audioqueuenewoutput(_:_:_:_:_:_:_:)), `AudioQueue.h:860-900`. | Creates an output queue for the supplied format; linear PCM must be interleaved, and a null callback run loop selects an internal thread. | Creation is not a documented start, but it also does not promise when an AudioProcess object becomes visible or a tap can attach. |
| [CurrentDevice](https://developer.apple.com/documentation/audiotoolbox/kaudioqueueproperty_currentdevice), `AudioQueue.h:206-210`. | A read/write device UID; queues tracking the system default receive a property notification when that device changes. | Explicitly select and read back the intended device in both arms; binding success does not certify process registration, active output, or untouched startup state. |
| [AudioQueueEnqueueBuffer](https://developer.apple.com/documentation/audiotoolbox/audioqueueenqueuebuffer(_:_:_:_:)), `AudioQueue.h:1116-1145`. | Assigns a buffer to the queue for playback or recording. | Ordinary pre-start enqueueing is setup for this control, but no registration or no-internal-preparation guarantee is specified. |
| [AudioQueueStart](https://developer.apple.com/documentation/audiotoolbox/audioqueuestart(_:_:)), `AudioQueue.h:1228-1243`. | Begins playback and starts the hardware if necessary; a supplied sample time uses the associated device timeline. | The first invocation must occur only after the parent has armed capture and sends GO. |
| [AudioQueuePrime](https://developer.apple.com/documentation/audiotoolbox/audioqueueprime(_:_:_:)), `AudioQueue.h:1246-1277`. | Decodes and prepares enqueued frames before playback, returning the prepared-frame count when requested. | Explicit priming before capture changes this agreed unprimed first-start test; label a primed variant separately rather than treating it as equivalent. |
| [Volume](https://developer.apple.com/documentation/audiotoolbox/kaudioqueueparam_volume) and [volume ramp time](https://developer.apple.com/documentation/audiotoolbox/kaudioqueueparam_volumeramptime), `AudioQueue.h:394-421`. | Queue volume is linear gain with default one; a configured ramp time governs subsequent volume changes in seconds, and the getter returns the current parameter value. | A readback of one does not reveal every internal gain state or prove the first sample is unchanged; the inspected contract supplies no default ramp-time value or exact recurrence. |
| `AudioQueueGetParameter`, `AudioQueue.h:1376-1400`. | The current parameter value can be queried at any time. | Record readback statuses and values in both arms; an unsupported or failed ramp-time read remains unknown, never fabricated as zero. |
| `kAudioQueueProperty_IsRunning`, `AudioQueue.h:196-199`, and `AudioQueueOutputCallback`, `AudioQueue.h:671-684`. | Running notifications correspond to device start/stop rather than necessarily the call time; the buffer callback indicates that its data has been consumed and the buffer can be reused. | Neither Start returning nor all buffers being reusable proves complete delivery through the capture path; use the full finite-reference comparison and actual post-roll. |

Apple's archived [Core Audio Essentials](https://developer.apple.com/library/archive/documentation/MusicAudio/Conceptual/CoreAudioOverview/CoreAudioEssentials/CoreAudioEssentials.html) distinguishes direct queue-volume setting from buffer-scheduled parameter setting.
Neither that guide nor the inspected current headers specifies `g[0] = 0`, coefficient `Float32(0.002)`, channel-state sharing, or the observed rounding expression.
Priming is documented preparation, not documented audible playback; its potential effect on hidden startup processing remains unknown.

## Registering a process before its first start

The [HAL process list](https://developer.apple.com/documentation/coreaudio/kaudiohardwarepropertyprocessobjectlist) contains clients connected to the audio system, according to `AudioHardware.h:586-588`.
[PID translation](https://developer.apple.com/documentation/coreaudio/kaudiohardwarepropertytranslatepidtoprocessobject), `AudioHardware.h:589-595`, can return success with `kAudioObjectUnknown` when there is no corresponding process object.
The process's device list and `IsRunning`/`IsRunningOutput` properties describe different aspects of its current activity, as documented at `AudioHardware.h:1953-1975`.
Registration is therefore distinct from active rendering.

Creating a queue or binding its device may connect a fresh child to Core Audio early enough to expose its process object.
That is an implementation hypothesis to observe, not a guarantee found in the public contracts.
Record the PID-translation result after creation, binding, and enqueueing, and verify any nonzero object's PID before using it.
Record running and device properties separately, preserving missing or failed reads.
Because the registration trigger is unspecified here, the possibility that an initial HAL query establishes client-side connection state remains unverified; preserve the same discovery sequence in both arms and do not claim that NewOutput alone caused registration.

The device-specific tap initializer describes a mix of selected process output directed to a selected device stream at `CATapDescription.h:86-97`.
It does not document that a never-started AudioQueue must already have a tap-usable process stream.
Successful tap creation, aggregate setup, and capture start before GO are preparation observations; they are not a substitute for checking the first reference sample in the recorded result.
For nonzero `kAudioAggregateDeviceTapAutoStartKey`, `AudioHardware.h:1635-1643` says aggregate start waits for the first tapped audio and describes `AudioDeviceStart` waiting until a tapped process receives it.
Waiting for that call to return before allowing an otherwise unstarted child to receive GO may therefore create a circular dependency, although these comments do not resolve every concrete scheduling detail.
Record start-requested, start-returned, and first-callback timestamps separately rather than collapsing them into one ready flag.
Requiring a pre-GO audio callback and then starting silence to obtain one would change the experiment.

If no usable process can be found with the agreed create, bind, and enqueue sequence, end that attempt as an unprepared or unsupported first-start capture on this setup.
Do not add Prime, start/pause, a prior silent queue, or a second renderer merely to make discovery succeed while retaining the original experiment label.

## Matched-control requirements and inference limits

Use a fresh child process and fresh queue for each arm, with the same source bytes, interleaved ASBD, device, buffers, callback scheduling, tap policy, capture timing, and discovery sequence.
The sole intended change is no volume setter versus exactly one successful `AudioQueueSetParameter(queue, kAudioQueueParam_Volume, 1)` at the same documented pre-start stage.
Read volume and ramp time in both arms without changing the ramp-time parameter.
Log monotonic timestamps and counts for queue creation, device binding, enqueue completion, optional parameter assignment, capture arming, GO, the first Start call, callbacks, and stop/disposal.
Record explicit Prime and Start invocation counts so a warmup or retry cannot masquerade as the first invocation.

If both arms preserve the entire original, the result shows only that this configured AudioQueue path did not reproduce the onset in these attempts.
It does not attribute Spotify's onset to Spotify or exclude a shared macOS mechanism requiring different triggering conditions.
If both show the exact signature, the signature can arise without Spotify under those measured conditions, but that does not identify the same internal component or implementation.
If only one arm differs, volume assignment becomes a bounded causal candidate for this helper; replication and preserved setup evidence are needed before generalization.
If capture starts after Prime or Start, the result belongs to a prepared or already-started condition and cannot answer the agreed unprimed first-start question.
Missing opening samples, unsuccessful process discovery, or incomplete capture are invalid preparations or incomplete results, not evidence that the onset is absent.
