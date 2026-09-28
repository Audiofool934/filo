# Core format matching

[Back to the documentation index](README.md) · [Architecture](ARCHITECTURE.md#format-matching) · [Validation](VALIDATION.md#110-format-matching-precision-and-menu-bar)

Format matching is filo's default path and its core product.
Its goal is to follow usable source-rate evidence, manage the selected output predictably, and preserve external device changes.
It leaves audio on the player's ordinary path: it creates no process tap and needs no audio-process discovery, BlackHole, Hog Mode, or recording permission.

This document is the behavior contract and acceptance matrix for that path.
Changes to detection, device ownership, or format selection should keep every row true and extend the matrix when they add a case.
The [validation record](VALIDATION.md#110-format-matching-precision-and-menu-bar) and its [structured receipt](validation/core-format-matching.json) separate completed software checks, bounded live observations, and outstanding acceptance work.

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

## Integer precision and device containers

Format matching uses known integer source depth from a Music decoder observation or the original local-file header.
ALAC flags supply its source depth; integer PCM uses its valid bit count rather than the decoder's working container.
Floating-point local files do not imply an equivalent integer source depth.
Unknown depth, manual selections, and Spotify's profile do not request a new physical depth.

Only advertised shared stereo PCM formats at the target rate are considered.
The policy prefers exact integer depth, then the smallest adequate precision, keeping an already selected equivalent container where possible.
A 32-bit float format has 24 bits of significand precision; it is adequate for 24-bit integer PCM but not every 32-bit integer value.
If no adequate format exists, playback continues at the matched rate with a visible depth limitation.
A non-mixable format is rejected before changing its rate.
The app reads back the resulting physical format and does not treat a selected menu label as proof of a hardware write.

The lease journals both rate and physical representation, including depth-only changes.
An external physical-format change ends ownership just as an external rate change does.
Restoration retries preserve journal state when the rate has already returned but restoring the original representation fails.

## Device ownership and restoration

Resolve the selected device from its persistent UID using a fresh device list before changing its route or rate.
Validate the current default route, rate, and physical representation before every requested match, including a request that would otherwise require no write.
An external change before the first write must not be overwritten or hidden because it happens to equal the newly detected source rate.
Track successful or possibly effective writes for recovery, without treating an untouched already-matching rate as an owned change.
On disconnect or quit, restore only still-owned changes; retain recovery information when a disconnected device prevents restoration.
Unexpected process exit recovery must resolve persistent identities again, and a reused hardware object ID must never redirect a write to another device.
Sleep, unplugging, or external route/rate changes end the connection and require an explicit reconnect.

## Acceptance matrix

The rows below define acceptance requirements; the validation record identifies which checks and live scenarios have actually run.
Automated tests use fake device access or fixture/helper processes and do not establish actual DAC behavior.

| Scenario | Acceptance | Targeted automated coverage |
| --- | --- | --- |
| Local tracks change 192 → 44.1 → 48 kHz, including repeated metadata | Exactly the necessary rate changes occur, the output reflects each rate, and Format matching makes no audio-process discovery calls. | `ConnectionControllerTests` |
| Decoder arrives late, lacks a timestamp, or repeats after a skip | Stale or malformed data does not become fresh; consumed evidence is not assigned twice. | `DecoderEventParserTests`, `PolicyTests` |
| Rapid skips, prebuffering, conflicting rates, pause/resume | Ambiguity remains unknown until usable new evidence exists; local-file evidence keeps precedence. | `PolicyTests`, `SourceProcessingTests` |
| Decoder observer fails at startup or while connected | Failure stays visible, late callbacks are ignored, and a readable current local file can still match. | `ConnectionControllerTests` |
| Unsupported source followed by a supported source | The unsupported rate is not written, the connection remains usable, and the next supported rate matches. | `ConnectionControllerTests`, `LeaseTests` |
| External route/rate change before first write or during a no-op match | Stop management and preserve that change instead of silently taking ownership. | `ConnectionControllerTests`, `LeaseTests` |
| Known depth, duplicate containers, unsupported precision, external depth changes, partial format restoration | Select only adequate advertised formats, avoid repeated writes, and preserve external changes. | `PhysicalFormatTests`, `ConnectionControllerTests`, `LocalFileFormatCacheTests` |
| Disconnect, failed rate write, stale selection, ID reuse, orphaned recovery | Restore only owned settings, resolve by UID, and preserve unresolved recovery information. | `LeaseTests` |
| Manual rate and Spotify profile | Display their distinct evidence labels without implying automatic track-format detection. | Controller checks plus packaged UI acceptance. |

Run from the repository root with a macOS Swift toolchain that includes XCTest:

```sh
swift build -Xswiftc -warnings-as-errors
swift test --filter 'FiloCoreTests\.(ConnectionControllerTests|PolicyTests|DecoderEventParserTests|LeaseTests|SourceProcessingTests|PhysicalFormatTests|LocalFileFormatCacheTests)'
swift test
```

The focused command checks the affected core paths, while the full suite checks compatibility with the existing relay, PCM, and recovery code.
A Command Line Tools environment that cannot load XCTest is a validation limitation, not a passing test run; use the configured macOS CI or a complete local Xcode installation.
CI also compiles the finite-reference laboratory without hardware and packages both architectures:

```sh
bash scripts/verify-finite-reference.sh --check
bash scripts/build.sh --universal
```

These build and test commands do not establish live playback acceptance.
