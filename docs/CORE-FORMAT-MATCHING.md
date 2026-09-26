# Core sample-rate matching

The core product goal is to follow usable source-rate evidence, manage the selected output predictably, and preserve external device changes.
Format matching leaves audio on the player's ordinary path; it neither creates a process tap nor depends on audio-process discovery, BlackHole, Hog Mode, or recording permission.
This document describes the implementation contract and required acceptance checks for the current core changes.
The [validation record](validation/core-format-matching.json) separates completed software checks, bounded live observations, and outstanding acceptance work.

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

The rows below define acceptance requirements; the validation section identifies which checks and live scenarios have actually run.
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

## Recorded validation

On 2026-09-26, [direct-head CI for `2100f7d`](https://github.com/Audiofool934/filo/actions/runs/36228822482/job/108367906394) passed all 118 XCTest tests with zero failures on an ARM64 macOS 15.7.9 runner, including nine controller tests and four local-header cache tests.
The strict build, hardware-free finite-reference laboratory compile/help check, universal packaging, plist lint, and signature verification passed.
Both `filo` and `filo-lab` contained arm64 and x86_64 executables; Intel execution was not tested by this CI run.
The [PR merge check](https://github.com/Audiofool934/filo/actions/runs/36228825138/job/108367913968) also passed all 118 tests.
Earlier local Command Line Tools adapters exercised 19 policy/parser, 12 lease, and 7 controller test bodies separately from XCTest.
A later standalone check exercised eight new and existing test bodies for the local-header retry change.
The final review follow-up reproduced four failed title/attention assertions for unsupported rates before the fix, then passed all nine controller test bodies in a standalone check.
In `2100f7d`, the warning remains visible when Music pauses or Spotify's fixed target is applied before playback, with recovery text appropriate to automatic or fixed selection.
These final warning states have software regression coverage but were not physically tested in the packaged UI; the live observations below retain their earlier build revisions.
These results are pinned to their recorded revisions and do not validate subsequent changes automatically.

Packaged-app UI observations and independent HAL readbacks on a Sony NW-ZX706 exposed as WALKMAN confirmed manual 44.1 and 96 kHz on `acaf1fe`, followed by manual 192 kHz and the labeled Spotify 44.1 kHz profile on `dcf8e66`.
Changing the output to 48 kHz in Audio MIDI Setup ended management and preserved the external rate; the updated build also displayed the restored 48 kHz immediately after disconnect.
The Spotify check validated its fixed target policy without establishing a playing track's source format.

On `dcf8e66`, an owned five-second 44.1 kHz ALAC file in Music remained unknown on its first playback, leaving the output at 48 kHz.
On replay, the UI identified Music decoder evidence at 44.1 kHz and the independent output readback matched 44.1 kHz.
This replay is evidence for that decoder observation, not verification of local-file header fallback or reliable first-play detection.
After the reference ended, unknown source state retained 44.1 kHz; disconnect restored the session's original 48 kHz.
The imported library entry and its Music-managed copy were removed while the original fixture was preserved.
The first-play miss prompted the bounded local-header retry change included in `c3204fa` and its passing software checks.

Quitting the connected app restored an owned 96 kHz setting to the session's original 48 kHz, with an independent readback after exit.
Audio MIDI Setup was then used to restore the task's 192 kHz baseline; WALKMAN remained the default output with no Hog Mode owner.
The app and its helpers exited before a final acceptance sequence on `c3204fa`.

The universal `c3204fa` build used for the last live sequence started from the 192 kHz baseline, with fresh imports of the owned five-second ALAC and WAV fixtures.
Music Song Info confirmed the ALAC identity and its 44.1 kHz rate.
Its first playback showed Music decoder evidence at 44.1 kHz and an independent output readback of 44.1 kHz.
Both imported files played once as a list, but an explicit subsequent WAV selection remained unknown and no local-file header label was observed.
The successful ALAC observation therefore does not establish that the header change caused it, that the earlier miss is universally fixed, or that local-file fallback works in this live configuration.
Both imported entries and Music-managed copies were removed, the filtered library showed no items, and the original ALAC and WAV fixtures were preserved.
Music was stopped with no current track and Play disabled, filo and its helpers exited, and the final independent readback confirmed WALKMAN at the 192 kHz baseline as default output with no Hog Mode owner.
The scoped implementation and these bounded acceptance checks are complete; the limitations below remain explicit.
Automatic matching across multiple local-file sample rates, local-file fallback, physical unplugging, sleep, unsupported-rate handling, unavailable detection, and operation with recording access denied or BlackHole absent have not been established by these live checks.
Fake-device and fixture tests cover applicable policy and ownership cases, without converting unperformed hardware scenarios into live passes.
No subscription stream, PCM comparison, or receiver capture was tested in this acceptance sequence.
Matching device rates therefore establishes neither source sample identity nor zero-gap transitions or end-to-end bit-perfect playback.
