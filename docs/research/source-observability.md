# Source observability for a bit-perfect filo path

Research date: 2026-09-23.
This document separates documented APIs, source-code observations, historical reports, and engineering proposals.
No player was started, no audio was captured, and no user audio settings were changed during this research.

## Findings that determine the architecture

A process tap observes outgoing audio from an application, not a documented decoder callback that supplies the untouched subscription master.
Apple's example explicitly supports process filtering, muting the original output, and placing the tap into an aggregate device.
It does not promise identity with a decoded source file.
[Apple Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)

The installed macOS 26.5 SDK `CATapDescription.h` documents that a device-specific tap matches the selected device stream's format.
`AudioHardware.h` describes `kAudioTapPropertyFormat` as the tap data format available in the containing aggregate device.
Therefore, tap rate is not independent evidence of the original track rate, and matching tap and DAC rates cannot prove that the player avoided earlier conversion.
The inspected process-object properties expose identity, devices, and running state, but no original file sample rate.
[CATapDescription](https://developer.apple.com/documentation/coreaudio/catapdescription)

For local, unprotected files, filo can read the actual file format before playback using `AVAudioFile.fileFormat`, and read the decoded reference samples through its buffer API.
A controlled local-file player can consequently configure the output before scheduling the first frame.
That is a materially stronger starting point than guessing a streaming track's format after playback begins.
[AVAudioFile](https://developer.apple.com/documentation/avfaudio/avaudiofile)

For Apple Music subscription tracks, the documented MusicKit `Song.audioVariants` property reports available quality classes.
Its cases distinguish lossless and high-resolution lossless, but do not expose the exact currently selected sample rate and bit depth.
`ApplicationMusicPlayer` provides playback owned by an application, and `prepareToPlay()` buffers the starting queue entry, but the inspected public interface does not provide a raw PCM callback or a guarantee that a chosen DAC receives native samples.
Treat the absence claim as a bounded API review, not proof that no private framework could do it.
[Song](https://developer.apple.com/documentation/musickit/song), [audioVariants](https://developer.apple.com/documentation/musickit/song/audiovariants), [AudioVariant](https://developer.apple.com/documentation/musickit/audiovariant), [ApplicationMusicPlayer](https://developer.apple.com/documentation/musickit/applicationmusicplayer), [prepareToPlay](https://developer.apple.com/documentation/musickit/musicplayer/preparetoplay())

## Apple Music metadata and processing controls

The following comes from the Music application itself, inspected as a read-only scripting dictionary at `/System/Applications/Music.app/Contents/Resources/com.apple.Music.sdef`.
It is a shipped interface description, not evidence that every cloud track answers every query promptly.

| Property | Scope | Intended use | Limitation |
| --- | --- | --- | --- |
| `sound volume` | Application | Detect digital attenuation; maximum is 100 | Maximum alone does not exclude other processing |
| `mute` | Application | Detect muted playback | Unknown must not become false |
| `EQ enabled` | Application | Detect application equalizer | Does not describe Sound Enhancer or spatial processing |
| `sample rate` | Track | Secondary metadata for local tracks | Does not identify the active subscription rendition reliably without a runtime test |
| `volume adjustment` | Track | Detect per-track adjustment; range is -100 to 100 | Read failure or missing cloud value must remain unknown |
| `EQ` | Track | Detect a selected per-track preset | A preset name alone does not establish the effective processing state |
| `location` | File track | Bind an unprotected file to its actual header and PCM | Cloud-track lookup may fail or time out |
| `persistent ID` | Item | Bind a supplemental observation to the same track | Some streaming items may provide empty or zero identifiers |

No Sound Check, Sound Enhancer, AutoMix, crossfade, Dolby Atmos, or current bit-depth property was found in this installed dictionary.
Apple documents these playback features in the Music user interface, including Sound Check's volume equalization and Sound Enhancer's processing.
A strict session must therefore separately establish their state instead of inferring that they are off from a successful scripting query.
[Music playback settings](https://support.apple.com/en-ie/guide/music/musdf855a1b/mac)

The current filo decoder parser accepts only `ACAppleLosslessDecoder` input-format diagnostics and correlates their arrival with a track transition.
This is useful evidence of a decoder configuration, but the diagnostics have no documented delivery deadline or permanent textual contract.
A prefetched track can be decoded before it becomes audible, and a format event need not identify the track that the user is hearing.
LosslessSwitcher itself describes a log-based switch occurring as soon as possible and warns about short interruptions.
[LosslessSwitcher source project](https://github.com/vincentneo/LosslessSwitcher)

A pause, configure, seek-to-start, and resume strategy could reduce wrong-rate playback at a first encounter, but must be treated as an experiment with visible transport changes.
It cannot silently claim full-track identity until the first-frame test confirms that the player actually rebuilds the relevant path and restarts at the correct sample.
Likewise, buffering already converted tap samples cannot recover the original samples by changing the DAC rate later.
These are engineering consequences of the defined sample-identity requirement, not additional Apple API guarantees.

## A useful historical regression hypothesis

In 2023, LosslessSwitcher's maintainer reported measurements in which Music's local-file path retained the output rate present when the app launched and performed additional conversion after a rate change.
The same report described different behavior for subscription playback.
This is historical, first-party project evidence, not a confirmed description of this machine's current Music version.
It means the fixture matrix must test both a fresh Music launch at the target rate and multiple rates inside one Music process.
A passing local test does not certify subscription playback, and a failing local test does not automatically show that subscription playback fails in the same way.
[Maintainer report and experiment description](https://github.com/vincentneo/LosslessSwitcher/discussions/74)

## Catalog-format prefetch is a hint, not selected-stream proof

WindowsLosslessSwitcher contains another approach: look up an Apple Music catalog item, inspect its enhanced HLS manifest, and choose the highest listed lossless sample rate and bit depth.
The inspected `AppleMusicCatalogResolver.cs` at commit `8084c5eec63fbb064200fa750201be5529180fad` obtains a web-app developer token and uses `extendedAssetUrls`; this is not a documented MusicKit PCM or active-renderer interface.
The code chooses a maximum available variant, which can differ from the rendition selected by a user's application, quality settings, region, download, or network condition.
The project is GPL-3.0; no implementation code was copied into filo.
[Inspected resolver](https://github.com/jordanmgibson/WindowsLosslessSwitcher/blob/8084c5eec63fbb064200fa750201be5529180fad/src/Services/AppleMusicCatalogResolver.cs), [license](https://github.com/jordanmgibson/WindowsLosslessSwitcher/blob/8084c5eec63fbb064200fa750201be5529180fad/LICENSE)

Do not use this mechanism as a strict source-format authority or introduce its token extraction into the release path.
An authorized, documented catalog integration could still provide a provisional preflight hint that must be corroborated by actual playback evidence.

## Spotify

Spotify's current support page documents lossless music up to 24-bit / 44.1 kHz FLAC for the desktop app, while its web player is documented as AAC.
This supports a labeled 44.1 kHz music profile, not a per-track claim that lossless is selected or available.
Automatic quality adjustment and the distinction between music, videos, and podcasts still matter.
[Spotify audio quality](https://support.spotify.com/us/article/audio-quality/)

Spotify's official exclusive-mode documentation currently lists the Windows desktop app as the supported platform.
It also identifies normalization, equalizer, Automix, and crossfade as settings relevant to unaltered playback.
That page is not evidence of a macOS exclusive-output API.
[Spotify exclusive mode](https://support.spotify.com/us/article/exclusive-mode/)

The Web API exposes catalog metadata and playback control, and the Web Playback SDK creates a browser player with playback state and volume controls.
The reviewed references do not expose decoded PCM, a hardware-device exclusive lease, or the selected track's exact lossless format.
Replacing the desktop source with a browser SDK is therefore not an evidenced route to the desired macOS lossless output.
[Web API](https://developer.spotify.com/documentation/web-api), [Web Playback SDK reference](https://developer.spotify.com/documentation/web-playback-sdk/reference)

The installed `/Applications/Spotify.app/Contents/Resources/Spotify.sdef` exposes volume, state, position, identity, and transport control.
It does not expose mute, sample rate, bit depth, lossless selection, normalization, or equalizer state.
A Spotify volume of zero can establish zero volume, but cannot reveal a separate mute property that the interface does not supply.

## Ranked implementation options

| Rank | Option | What it can establish | Decision |
| --- | --- | --- | --- |
| 1 | Known local PCM through Music and an independent digital capture | Whether the actual Music path preserves a precisely known fixture | Implement first as a source-boundary experiment |
| 2 | Direct local-file playback inside filo with exclusive physical output | Complete control over source format, first-frame scheduling, and software processing | Strongest route to a narrowly defined strict mode; actual digital output still needs measurement |
| 3 | Split capture and exclusive DAC output, with a virtual source clock following DAC cadence | Isolation and unchanged sample transport after the player's output | Proceed only with zero-loss clock and sample verification, plus source-format preflight |
| 4 | Subscription playback with settings readback, log evidence, and explicitly gated transitions | Stronger diagnostics and fewer known alterations | Useful companion mode, but unknown source samples remain unverified |
| 5 | MusicKit or catalog metadata as a replacement for source PCM visibility | Queue control or provisional quality hints | Does not by itself close the source-equality gap |

A private virtual device must not mix arbitrary other applications into the selected source.
If a split path uses independently clocked devices, changing the virtual clock cadence might avoid resampling, whereas dropping, repeating, or interpolating samples cannot meet the strict definition.
The latter topology and its timing tests are addressed separately in the exclusive-output research.

## Objective Music fixture procedure

1. Generate original deterministic stereo WAV fixtures at 44.1, 48, 96, and 192 kHz with 16-bit and 24-bit integer PCM.
   Include distinct channels, varying low bits, an unambiguous start marker, nonrepeating payload, and an end marker.
   Use quiet amplitude for any audible physical run, and exercise full-scale boundary patterns only on a silent digital sink.
2. Record each fixture's file hash, decoded PCM hash, expected frame count, channel order, sample rate, and bit depth.
   Decode any optional ALAC version and verify it against the WAV reference before using it to test Music's decoder.
3. Use Music's normal local-file import flow with only these task-owned fixtures.
   Track any library entries or copied files that the test creates; preserve unrelated user media and settings.
   Apple documents that import can copy files or create references depending on the user's Files settings.
   [Music local import](https://support.apple.com/guide/music/import-items-already-on-your-computer-mus3081/mac)
4. Read the available source controls and separately inspect the unavailable DSP controls.
   Run the first baseline at matching source/output rate before Music starts, then repeat with Music already open at a different rate.
5. Capture the Music process tap and, independently, the rendered virtual loopback or external digital receiver.
   Name each measurement boundary explicitly; compare a known input reference with what actually crosses that boundary.
6. For a full-track result, allow transport latency before the fixture start marker but require the first source frame, every payload frame, the end marker, and the exact expected length.
   A comparator that searches for an arbitrary internal offset and compares only the remaining tail can validate that tail, but cannot certify that no opening frames were lost.
7. Repeat natural transitions in both directions, same-rate album transitions, and a competing process playing a distinct test pattern.
   Record whether restart or gating adds silence, whether the first frame survives, and whether the competing signal is rejected.
8. Add negative controls with application attenuation, EQ, and mismatched rates.
   The sample comparator must reject these instead of silently compensating for gain, delay changes, missing frames, or resampling.
9. Release task-owned capture processes and imported fixtures, restore only settings still owned by the experiment, and report cleanup evidence.

Subscription testing should retain only configuration, timing, frame counters, error counters, and other non-audio diagnostics.
It should not write subscription PCM to disk or compare a purchased/local recording merely because its title matches a streamed track.
Different masters or renditions make that comparison inconclusive even before transport is considered.
A verifiable subscription reference requires an authorized, exact reference with established rendition identity, or a vendor-supported digital bit-test.

## Strict eligibility contract for source evidence

Treat the following as separate evidence states: known local reference, observed decoder format, manually selected rate, and unknown.
Never promote the latter three to known-source sample equality.
Application volume, mute, EQ, per-track adjustment, and preset observations need explicit timestamps and track identity, and missing values remain unknown.
A cached per-track observation describes that observation time only; a later user edit can invalidate it.
Readback flags are necessary diagnostics, not a substitute for checking unexposed processing or comparing samples.

A strict session should fail closed if source format is unknown, a known modifier is active, output loses ownership, a clock fault occurs, or the source/tap/output rates diverge.
If the application cannot verify an unexposed setting, report that limitation separately instead of fabricating a safe value.
A tested path can be labeled by its actual evidence boundary, such as “local reference to digital loopback verified,” and must not be relabeled “all subscription streams to WALKMAN verified.”
