# Primary-source search for the Spotify onset signature

Retrieved and inspected on 2026-09-25.
This was a read-only documentation and public-source investigation, with no playback, HAL calls, player changes, private-binary inspection, or production changes.

## Result

No exact source match or supported control for this particular onset was found in the bounded sources below.
The measured signature remains an empirical description, not an attribution to Spotify, Core Audio, an Audio Unit, or BlackHole.
The [measured onset observation](spotify-onset-observation.md) and [receipt index](../validation/spotify-onset/index.json) record the experimental evidence.

The signature to explain is common stereo gain with `g[0] = 0`, `alpha = Float32(0.002)`, `y[n,c] = Float32(x[n,c] * g[n])`, and a gain update with one final Float32 rounding of `g + alpha * Float32(1 - g)`.
It reproduces all 1,024 retained sample words from one 512-frame callback.
Two related arithmetic formulations match, so even an apparent coefficient match would not establish a particular expression or machine instruction.
This search found mechanisms that can change gain, but none documenting that coefficient, initial condition, shared-channel state, and rounding behavior together.

## Supported contracts and source inspection

The local header evidence is from the Command Line Tools macOS 26.5 SDK, while the recorded measurement used macOS 26.6.2.
Headers describe the public contract, not the private implementation of the measured operating-system build.
The SDK root was `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`.

| Primary source | What it establishes | What it does not establish |
| --- | --- | --- |
| [Core Audio tap sample](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps), [CATapMuteBehavior](https://developer.apple.com/documentation/coreaudio/catapmutebehavior), `CoreAudio.framework/Headers/AudioHardware.h:1993` and `CATapDescription.h:19-42`. | A tap obtains output-derived audio from selected processes; the mute policies determine whether their audio also reaches hardware. | No documented position relative to every internal gain stage, startup gain state, fade coefficient, or pre-processing bypass selector was found. |
| [kAudioDevicePropertyProcessMute](https://developer.apple.com/documentation/coreaudio/kaudiodevicepropertyprocessmute), `AudioHardware.h:991-994` and its AudioProcess property list. | This device property concerns the calling process, causes the system to zero its audio, and excludes aggregate devices. | It is not a supported way for filo to change Spotify's private gain state; the inspected AudioProcess property list provides no volume or smoothing-state parameter. |
| [kHALOutputParam_Volume](https://developer.apple.com/documentation/audiotoolbox/khaloutputparam_volume), `AudioToolbox.framework/Headers/AudioUnitParameters.h:323-327`. | The output-unit parameter is global linear gain, ranging from zero to one and defaulting to one. | Its declaration does not specify dezippering, an initial zero gain, or Float32 arithmetic; another application's Audio Unit instance is not exposed by this parameter. |
| [AudioUnitScheduleParameters](https://developer.apple.com/documentation/audiotoolbox/audiounitscheduleparameters(_:_:_:)), [scheduleParameterBlock](https://developer.apple.com/documentation/audiotoolbox/auaudiounit/scheduleparameterblock), `AUComponent.h:1480-1502` and `AUAudioUnit.h:156-179`. | Hosts can schedule immediate changes or ramps over specified sample frames for parameters supporting ramps. | These contracts do not prescribe this exponential recurrence or make every volume change use a particular ramp. |
| [AudioQueue volume ramp time](https://developer.apple.com/documentation/audiotoolbox/kaudioqueueparam_volumeramptime), `AudioQueue.h:394-421`. | A queue has unity volume by default and can apply subsequent volume changes over a configured duration in seconds. | No documented `0.002` coefficient, startup ramp requirement, or exact numerical implementation appears in this contract. |

Apple's public [AudioUnitSDK](https://github.com/apple/AudioUnitSDK/tree/bd98b31feff57a15989fcfab4cd86dc63382b1ac) was inspected at revision `bd98b31feff57a15989fcfab4cd86dc63382b1ac`.
A search of its 32 C/C++/Objective-C source and header files for `0.002`, `.002f`, `dezip`, `smooth`, and `ramp` found scheduling infrastructure, not this smoothing implementation.
The base [AUElement::SetScheduledEvent](https://github.com/apple/AudioUnitSDK/blob/bd98b31feff57a15989fcfab4cd86dc63382b1ac/src/AudioUnitSDK/AUScopeElement.cpp#L112-L125) rejects unsupported ramp events instead of imposing a universal smoothing algorithm.
This is public Audio Unit implementation infrastructure, not the source of Apple's shipped output unit or Spotify's renderer.

The measured BlackHole version's [v0.5.0 ReadInput path](https://github.com/ExistentialAudio/BlackHole/blob/v0.5.0/BlackHole/BlackHole.c#L4536-L4564) copies its ring-buffer data and applies `vDSP_vsmul` with the current master scalar.
Its source initializes that scalar to one and directly assigns new scalar values in the setter; no `0.002` literal or per-frame gain recurrence appears in that file.
This identifies a different published gain mechanism and is consistent with the already documented separate loopback-level confound.
It does not exclude processing elsewhere in macOS.

Spotify's [Connect Basics](https://developer.spotify.com/documentation/commercial-hardware/implementation/guides/connect-basics#reacting-to-volume-changes) gives the embedded-device integrator responsibility for applying volume through its driver or sample processing.
Its [hardware requirements](https://developer.spotify.com/documentation/commercial-hardware/implementation/requirements/technical#audio-quality-and-volume) require avoiding audible glitches and specify volume-state propagation, without prescribing this smoothing algorithm.
These are hardware-integration contracts, not evidence of the macOS desktop renderer's implementation.
The [Web API volume endpoint](https://developer.spotify.com/documentation/web-api/reference/set-volume-for-users-playback) accepts integer percentages and does not guarantee ordering with other Player API calls, so it cannot provide a sample-timed initialization control.
The [Soloist command-line documentation](https://developer.spotify.com/documentation/soloist/reference/command-line#playback-and-audio-options) concerns Linux PipeWire/PulseAudio output and supplies no macOS explanation.
No inspected official Spotify source identifies the observed recurrence or exposes a desktop startup-ramp bypass.

## Controls suggested by the sources

The [subsequent prewarm experiments](spotify-prewarm-observation.md) provide related measurements for the silent-prefix idea below, rather than every matched control described here.
The AudioQueue and output-unit controls remain unexecuted proposals, not a playback workaround.
Each should retain the existing strict comparator and compare newly measured raw words with its own validated synthetic reference.

1. Change only the length of leading digital silence within a synthetic WAV while holding the established source and capture setup constant.
   If the original nonzero payload becomes exact after a silent prefix, that supports advancement of gain state while the renderer processes silence; if the same zero-start onset occurs at the first nonzero sample, it supports a signal-dependent reset or trigger instead.
   Neither outcome identifies the component, and digital silence alone cannot reveal the gain that was applied to it.
2. In a controlled AudioQueue helper, compare the default unity setting against one explicit unity-volume assignment before start, keeping source bytes, route, tap policy, queue initialization, and capture timing identical.
   An exact recurrence appearing in this independent source would show that Spotify is not necessary for that signature; absence would not exclude a shared macOS mechanism with different triggering conditions.
   Read back the queue volume and ramp-time parameter when supported instead of assuming their state.
3. For a controlled output-unit source, compare continuously rendering zeros before the unchanged reference against starting the render unit immediately before that reference, with the tap already armed in both cases.
   This changes renderer pre-roll while preserving the nonzero sequence and tests whether render-start state matters independently of Spotify's track selection.
   Existing neutral AVAudioPlayer and finite-emitter passes are useful baselines, but neither substitutes for this matched pair.

The already completed mute-policy and clock-following controls should not be repeated merely because these public APIs mention mute or clocks.
There is no primary-source basis here for changing filo's strict rejection, rounding the rejected samples, inverting the fitted gain, or claiming that a public smoothing-disable switch has been found.
