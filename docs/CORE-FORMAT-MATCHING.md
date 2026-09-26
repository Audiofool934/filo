# Core sample-rate matching

The core product goal is to follow usable source-rate evidence, manage the selected output predictably, and preserve external device changes.
Format matching leaves audio on the player's ordinary path; it neither creates a process tap nor depends on audio-process discovery, BlackHole, Hog Mode, or recording permission.
This document describes the implementation contract and required acceptance checks for the current core changes.
Execution results for these changes are pending and must be recorded separately before claiming a verified release.

## Evidence and behavior

| Evidence or condition | Required behavior |
| --- | --- |
| Readable local Music file for the current track | Prefer its format over an unassociated decoder message. |
| Fresh lossless Music decoder diagnostic near a track transition | Use the event timestamp and playback observation time; allow a bounded association window. |
| Delayed, replayed, conflicting, or ambiguous decoder evidence | Do not invent a current format or reuse an already assigned observation for another track. |
| Unknown source | Keep the current output rate and show uncertainty. |
| Decoder observer startup or runtime failure | Keep the detection failure visible; reject late decoder callbacks; allow current local-file evidence to match. |
| Unsupported detected rate | Keep ordinary playback and the current rate, show the mismatch, and resume automatic matching when a supported track arrives. |
| Manual selection | Apply the requested supported rate and label it as manual; automatic detection is off. |
| Spotify profile | Apply the labeled fixed 44.1 kHz policy; do not describe it as per-track detection. |

Music diagnostics do not carry an authenticated track identity and can reflect prebuffering.
Freshness and ambiguity checks reduce known mistakes but do not make every subscription format readable or prove an association in every rapid-skip sequence.
Rate changes may arrive after the opening of a track and may interrupt playback briefly.
Neither matching rates nor a hardware bit-depth display proves unchanged samples, source precision, zero-gap transitions, or receiver equality.

## Device ownership and restoration

Resolve the selected device from its persistent UID using a fresh device list before changing its route or rate.
Validate the current default route and rate before every requested match, including a request that would otherwise require no write.
An external change before the first write must not be overwritten or hidden because it happens to equal the newly detected source rate.
Track successful or possibly effective writes for recovery, without treating an untouched already-matching rate as an owned change.
On disconnect or quit, restore only still-owned changes; retain recovery information when a disconnected device prevents restoration.
Unexpected process exit recovery must resolve persistent identities again, and a reused hardware object ID must never redirect a write to another device.
Sleep, unplugging, or external route/rate changes end the connection and require an explicit reconnect.

## Acceptance matrix

All rows below are acceptance requirements, not a record that the new checks or live scenarios have already passed.
Automated tests use fake device access or fixture/helper processes and do not establish actual DAC behavior.

| Scenario | Acceptance | Targeted automated coverage |
| --- | --- | --- |
| Local tracks change 192 → 44.1 → 48 kHz, including repeated metadata | Exactly the necessary rate changes occur, the output reflects each rate, and Format matching makes no audio-process discovery calls. | `ConnectionControllerTests` |
| Decoder arrives late, lacks a timestamp, or repeats after a skip | Stale or malformed data does not become fresh; consumed evidence is not assigned twice. | `DecoderEventParserTests`, `PolicyTests` |
| Rapid skips, prebuffering, conflicting rates, pause/resume | Ambiguity remains unknown until usable new evidence exists; local-file evidence keeps precedence. | `PolicyTests`, `SourceProcessingTests` |
| Decoder observer fails at startup or while connected | Failure stays visible, late callbacks are ignored, and a readable current local file can still match. | `ConnectionControllerTests` |
| Unsupported source followed by a supported source | The unsupported rate is not written, the connection remains usable, and the next supported rate matches. | `ConnectionControllerTests`, `LeaseTests` |
| External route/rate change before first write or during a no-op match | Stop management and preserve that change instead of silently taking ownership. | `ConnectionControllerTests`, `LeaseTests` |
| Disconnect, failed rate write, stale selection, ID reuse, orphaned recovery | Restore only owned settings, resolve by UID, and preserve unresolved recovery information. | `LeaseTests` |
| Manual rate and Spotify profile | Display their distinct evidence labels without implying automatic track-format detection. | Controller checks plus packaged UI acceptance. |

Run from the repository root with a macOS Swift toolchain that includes XCTest:

```sh
swift build -Xswiftc -warnings-as-errors
swift test --filter 'FiloCoreTests\.(ConnectionControllerTests|PolicyTests|DecoderEventParserTests|LeaseTests|SourceProcessingTests)'
swift test
```

The focused command checks the affected core paths, while the full suite checks compatibility with the existing relay, PCM, and recovery code.
A Command Line Tools environment that cannot load XCTest is a validation limitation, not a passing test run; use the configured macOS CI or a complete local Xcode installation.
The existing CI also compiles the finite-reference laboratory without hardware and packages both architectures:

```sh
bash scripts/verify-finite-reference.sh --check
bash scripts/build.sh --universal
```

These build and test commands do not establish live playback acceptance.
Before release, separately record a packaged-app sequence with supported rates changing downward and upward, unknown/manual/profile displays, unavailable detection, and unsupported-rate handling where the device permits it.
Also record disconnect/quit restoration and an intervening user route/rate change, including confirmation that Format matching works without recording access or BlackHole.
Capture the app revision, device, initial settings, resulting UI/output state, and restoration outcome; mark any unexercised scenario as untested.
Do not replay old relay measurements as evidence that these current matching changes passed, and do not infer sample identity from a matching rate display.
