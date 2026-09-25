# Spotify prewarm integration feasibility

Inspected on 2026-09-25 without sending Apple Events, Web API commands, UI actions, or audio to Spotify.
Only public documentation, the installed public scripting dictionary, current filo source, and existing receipts were read.

## Decision

The observed queued prewarm is a useful research result, but the inspected supported interfaces are insufficient for a reliable transparent feature that preserves an arbitrary existing queue and guarantees an unchanged first playback.
A user-prepared local-file sequence can support further explicit experiments without private APIs or DRM access.
That is a narrower workflow than automatically intercepting any Play action and inserting silence without changing the user's session.
Do not ship a bypass or promote the one successful sequence into a general claim.

The inspected [continuous zero-warmup receipt](../validation/spotify-prewarm/onset2-continuous-zero-warmup.json) passed all 220,500 reference frames and 1,764,000 signed32 bytes, with no mismatches, representation failures, timing faults, or cleanup errors.
Its SHA-256 is `3648eb80b59885bca49b9b0ea436fe47e658ea6cabd1c72b2f2f9816a5f531ef`, and its aligned output hash is `8fd04325bfb401bac8d2700c967453319a12e7ead41dde6ee04505e64e118ea5`.
The [experimental sequence](spotify-prewarm-observation.md) played five seconds of pure zero in Spotify followed by the manually queued original within one relay session.
The preceding [silence-prefix trial](../validation/spotify-prewarm/onset2-silence-first.json) preserved its active four-second payload.
Selecting the [original after teardown](../validation/spotify-prewarm/onset2-original-after-silence.json) then failed with the same 1,024 raw onset words as the earlier rejected-input measurement.
The silent prefix cannot independently establish how many source-silent frames played, since external capture silence is indistinguishable.
These observations motivate preserving source continuity; they do not identify which component's state is preserved or prove that silence always produces it.

## Concrete supported primitives

The installed Spotify is version `1.3.0.277`.
Its public scripting dictionary at `/Applications/Spotify.app/Contents/Resources/Spotify.sdef` has SHA-256 `c5746acd3ca998ff3c69e61035bc8de5f2fd2f6a8fd9eaa72a91fadf44b9f28b`.
Reading this XML did not invoke the application or inspect a private binary.

| Interface | Exposed primitive | Limitation for prewarm integration |
| --- | --- | --- |
| Installed scripting dictionary. | Read current track identity and metadata, player state, volume, position, repeat and shuffle state. | No queue collection, queue snapshot, current context readback, renderer readiness, pre-play interception, or sample-format declaration is exposed. |
| Installed scripting dictionary. | Resume, pause, toggle, next, previous, seek by setting position, adjust volume/repeat/shuffle, and `play track` with an optional context URI. | No enqueue, insert-before-current, remove-queued-item, restore-queue, import-local-file, source-folder, or DSP-setting command is exposed. |
| [Web API queue read](https://developer.spotify.com/documentation/web-api/reference/get-queue). | Read the current item and upcoming queue objects with OAuth read scope. | Its response has no queue revision, compare-and-swap token, or atomic restore contract; a read cannot reserve the session against concurrent user or other-device changes. |
| [Web API enqueue](https://developer.spotify.com/documentation/web-api/reference/add-to-queue). | Enqueue a track or episode URI on a selected device with Premium and modification scope. | No position argument, queue replacement, or removal primitive is provided here; ordering with other Player API operations is explicitly not guaranteed. |
| [Web API start/resume](https://developer.spotify.com/documentation/web-api/reference/start-a-users-playback). | Start a supplied context or list of track URIs, optionally at an offset and position. | This initiates playback rather than intercepting it, and supplies neither a renderer-continuity guarantee nor a transaction preserving an arbitrary previous queue. |

No scripting command above was exercised, so accepting a particular `spotify:local:` URI remains untested in this audit.
The generic URI parameter is not a documented promise that an arbitrary new file path can be opened or imported.
Spotify documents local URIs as metadata-derived identifiers, not file paths or content hashes, and explicitly disallows adding local files to playlists through the Web API.
This playlist limitation should not be overstated as proof that every existing local URI is rejected by the queue endpoint; that support was not established by the inspected queue contract. [Local-file API documentation](https://developer.spotify.com/documentation/web-api/concepts/playlists#local-files).

Spotify's supported desktop local-file setup requires enabling Local Files and selecting source folders in Settings.
A generated silent WAV can be owned by filo, but making Spotify discover it requires an explicit user setup flow or prior user configuration, not a silent preference edit. [Spotify local-file instructions](https://support.spotify.com/us/article/local-files/).
Playlist snapshot IDs apply to playlists, not the playback queue, and therefore do not fill the missing queue transaction. [Playlist versioning](https://developer.spotify.com/documentation/web-api/concepts/playlists#version-control-and-snapshots).
The Web Playback SDK creates a browser playback device, so it would introduce a different source path rather than prewarm the existing desktop process. [SDK overview](https://developer.spotify.com/documentation/web-playback-sdk).

## Fit with filo's existing lifecycle

[PlayerReader](../../Sources/FiloCore/PlayerReader.swift) currently reads Spotify state, identity, and volume only, first checking that the application is already running.
It neither starts playback nor owns a queue, Spotify login, or Web API client.
The application observes playback-change notifications to request another read, while [ConnectionController](../../Sources/FiloCore/ConnectionController.swift) also polls once per second.
Neither mechanism is a supported before-first-sample hook that can hold a user's Play action until prewarm completes.

The Spotify profile selects 44.1 kHz as policy evidence, without establishing per-track rate or bit depth.
For that explicit-rate path, `ExclusivePlaybackPolicy` can arm before playback when the HAL process exists and does not restart solely because playing metadata changes from one track to the next.
That already accommodates a genuinely continuous silent-track-to-reference transition when the process set and format remain stable.
The corresponding [policy test](../../Tests/FiloCoreTests/ExclusivePlaybackPolicyTests.swift) checks these decisions, not Spotify's actual continuity.

The controller stops and rearms a segment on an observed playing-to-paused transition, metadata error, process-set change, or required format change.
Disconnect, sleep, route loss, and faults also invalidate the prior segment, with audio stopped before route restoration.
A future experimental warm-state indicator would therefore need invalidation on those events and could describe only an attempted preparation, never a verified hidden gain state.
Zero samples cannot reveal whether gain is zero, unity, or changing, so receiving enough silent frames is not a readiness certificate.

[SourceProcessingAssessment](../../Sources/FiloCore/SourceProcessingAssessment.swift) still marks Spotify normalization, Automix, crossfade, lossless selection, and other unread controls as unverified.
The GUI does not compare arbitrary playback against a known original reference.
Keeping its relay alive cannot turn those unknowns into a first-play or arbitrary-source guarantee.

## Scope that remains defensible

- Continue treating explicit user-prepared silence followed by a chosen known file as a laboratory sequence, with the user retaining control of queue contents and local-file settings.
- Do not reconstruct a user's queue by replaying returned URIs: the inspected interfaces provide no lossless transaction for the original context, manual additions, ordering, and concurrent changes.
- Do not substitute an external silent filo stream for Spotify's silent track without measurement: another process does not establish that Spotify's renderer state advanced.
- Keep the original sample comparator and fault handling unchanged; neither prewarm nor a successful silent interval justifies rounding, gain inversion, or a green arbitrary-content verification label.

Generating and playing an owned silent file needs no DRM PCM access.
Fetching subscription PCM would not solve the missing queue and renderer-control contracts, and is not part of this proposal.
Reliable first play across arbitrary sources remains unsupported by both the single-pass evidence and the public control surface inspected here.
