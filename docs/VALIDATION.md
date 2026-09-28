# Validation record

[Back to the documentation index](README.md) · [Architecture](ARCHITECTURE.md) · [Laboratory](LABORATORY.md)

This is filo's record of what has been tested, how, and with what result, newest first.
Each result applies to the revision, software versions, and hardware it names; it does not validate later changes automatically.
Machine-readable receipts are in [`validation/`](validation/), and detailed investigations are in [`research/`](research/).

## Test setup

Unless a record says otherwise, hardware checks used one Apple Silicon MacBook Pro on macOS 26.6.2 (25G83), [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole) for silent virtual output, and a Sony NW-ZX706 that the Mac enumerates as **WALKMAN**.
Early records describe the NW-ZX706 as being in USB DAC mode; that was a setup assumption, later qualified by a [mode evidence correction](research/usb-dac-mode-correction.md).
CI runs the XCTest suite and packaging on GitHub's macOS 15 ARM64 runners, which have no DAC, Music subscription, or audio-capture permission.

## Summary

### Established under the recorded conditions

| Area | Result |
| --- | --- |
| Format matching | On the NW-ZX706, manual 44.1, 48, 96, and 192 kHz, the Spotify 44.1 kHz profile, and an automatic 48 kHz / 24-bit ALAC match reached their targets, with independent CoreAudio readback. Disconnect and quit restored the original rate and format, and outside rate changes were preserved. The 1.0 record includes a real Apple Music subscription transition from 192 to 44.1 kHz. |
| Shared relay | Synthetic 16 and 24-bit patterns at 44.1 to 192 kHz passed exactly at the process tap and through rendered BlackHole loopback, including 60-second runs and the Intel slice under Rosetta. |
| Exclusive transport | Synthetic 16 and 24-bit patterns at 44.1 to 192 kHz passed exactly at the WALKMAN output callback, including a 120-second run and a complete five-second reference, and a real process crash was recovered. |
| Real players on the exclusive path | A neutral AVAudioPlayer passed a complete ALAC reference to the WALKMAN output callback. Spotify passed complete local FLAC, WAV, and ALAC references in some runs. |
| Distribution | The 1.1.2 app and DMG were accepted by Apple's notary service, stapled, and accepted by Gatekeeper. |

### Not established

- Exact delivery of a known reference through Apple Music: the tested Music path changed the samples before they reached filo.
- Reliable exact first-start playback through Spotify.
- Identity with any subscription master.
- Samples in the USB payload or inside the DAC.
- Reliable detection for every track, including rapid skips, prebuffered transitions, and first plays of local files.
- Other DACs, physical Intel Macs, macOS versions before 26 at runtime, physical hotplug, sleep and wake, and power loss.

The [Exclusive preview guide](EXCLUSIVE-PREVIEW.md#what-has-been-measured) explains the evidence levels, from matching configuration to receiver-side measurement.

## Research index

| Date | Investigation | Finding |
| --- | --- | --- |
| 2026-09-23 | [Feasibility](research/feasibility.md) | Pre-implementation research: a format companion and a public-API relay are feasible; universal bit-perfect playback is not supported by the evidence. |
| 2026-09-23 | [Source observability](research/source-observability.md) | Which source-format signals Music and Spotify expose, and which they do not. |
| 2026-09-23 | [Exclusive paths](research/exclusive-paths.md) | The separate-source exclusive topology and sample-preserving bridge that became Exclusive preview. |
| 2026-09-23 | [Endpoint verification](research/endpoint-verification.md) | No receiver-side readback or passive USB payload capture is available with the current hardware. |
| 2026-09-23 | [Apple Music reference](research/music-reference-observation.md) | Music changed a known ALAC reference identically over HTTP and from a local file, before the tap. |
| 2026-09-24 | [Player API reference](research/player-api-reference-observation.md) | AVAudioPlayer preserved the same reference exactly; enabling rate adjustment changed it. |
| 2026-09-24 | [Spotify local reference](research/spotify-reference-observation.md) | Spotify preserved complete WAV, ALAC, and FLAC references at its BlackHole tap. |
| 2026-09-24 | [Spotify connected exclusive](research/spotify-exclusive-observation.md) | Six runs passed to the WALKMAN output callback; seven stopped on unrepresentable samples. |
| 2026-09-25 | [Spotify onset](research/spotify-onset-observation.md) | In one failed first start, a retained 512-frame window exactly matched the reference times an exponential gain onset. |
| 2026-09-25 | [Spotify onset sources](research/spotify-onset-primary-sources.md) | No documented source or control for that onset was found. |
| 2026-09-25 | [Spotify prewarm](research/spotify-prewarm-observation.md) | A silent file queued before the reference preserved it; a direct start still failed. |
| 2026-09-25 | [Prewarm integration](research/spotify-prewarm-integration-feasibility.md) | Spotify's supported interfaces cannot turn prewarming into a reliable feature. |
| 2026-09-25 | [AudioQueue control contracts](research/audioqueue-control-contracts.md) | Public AudioQueue, HAL, and tap contracts relevant to first-start behavior. |
| 2026-09-26 | [AudioQueue first start](research/audioqueue-first-start-observation.md) | Fresh AudioQueue sources preserved the complete reference, including its opening, under an experimental tap configuration. |
| 2026-09-26 | [Spotify tap autostart](research/spotify-tap-autostart-observation.md) | Disabling tap autostart did not prevent the Spotify onset. |
| 2026-09-26 | [USB DAC mode correction](research/usb-dac-mode-correction.md) | Earlier "USB DAC mode" statements are setup assumptions, not observed receiver state. |
| 2026-09-26 | [Spotify effects off](research/spotify-effects-off-observation.md) | Turning off Gapless and Automix did not prevent the onset. |

Dates are local dates of the measurement or research; the linked documents give exact times and time zones.

## 1.1.1 and 1.1.2

These patch releases changed the menu bar item, the card's window, and packaging; the audio engine did not change.
The native checks are recorded in the [menu bar design QA record](validation/menu-bar-design-qa.md).

- **1.1.1, build 9:** a fixed-width ƒ status item and an arrowless card replaced the popover.
  Native Apple Silicon checks covered the connection switch, details navigation, fixed card size, and Escape dismissal.
  The universal bundle passed strict signature and architecture checks; Intel execution and other macOS versions were not rechecked.
- **1.1.2, build 10:** the full visible area of the more button now responds to pointer clicks, verified at its center and four edges.
  The new DMG was visually inspected in Finder.
  Apple accepted both the app and DMG notarization submissions, both tickets were stapled and validated, and Gatekeeper reported `source=Notarized Developer ID` for each.
  The final ZIP was extracted separately and its app passed ticket validation and Gatekeeper assessment again.
  A fresh installation on a separate Mac or clean account was not verified.

## 1.1.0: format matching, precision, and menu bar

This release hardened automatic matching and device ownership, added bit-depth negotiation, and introduced the Liquid Glass menu bar card.
The behavior contract and acceptance matrix are in [Core format matching](CORE-FORMAT-MATCHING.md).

### Automated checks and live acceptance

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

### Menu bar and precision follow-up

The `feat/liquid-glass-menubar` implementation adds advertised physical-format negotiation, current-track local-file depth, external depth ownership, and retryable format restoration.
It removes disconnected polling timers and enables the 100 ms clock timer only for an active exclusive relay.
Hardware property listeners coalesce changes for 100 ms; connected format matching checks playback every two seconds with a ten-second hardware refresh fallback.
Every requested match still checks fresh ownership, including repeated source metadata that requires no write.
Visible snapshots ignore observation-only timestamp changes, and the closed panel does not request artwork.
These are implementation properties, not measured energy or latency guarantees.

On 2026-09-26, the local strict Swift build and hardware-free finite-reference compile/help check passed on macOS 26.6.2.
A standalone assertion adapter executed all 133 current XCTest test bodies with zero assertion failures, including rate/depth transitions, external changes, partial restoration, source-header precision, and snapshot deduplication.
The adapter linked the actual debug FiloCore and FiloPCM objects; it did not execute Apple's XCTest framework.
Local `swift test` could not compile because this Command Line Tools installation does not include XCTest.
CI is configured to select Xcode 26.3, listed in the [GitHub macOS 15 runner image](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md#xcode), for the macOS 26 SDK and full XCTest.
No CI result for this follow-up is claimed here.
The local beta.5 universal bundle passed strict signature verification, plist lint, both architecture checks for both executables, and byte-for-byte comparison of its four bundled scenes with the source assets.
Intel execution was not tested.

On 2026-09-27, the desktop and WALKMAN were available for native acceptance of the beta.5 menu bar implementation.
Native testing exposed flattened menu labels, incomplete selector hit areas, duplicate accessibility controls, and a reopen event that reset secondary pages.
The resulting fixes preserve glass menu labels, full-width click areas, one accessibility element per selector, and the current page while the popover remains open.
The final strict Swift build and universal arm64/x86_64 packaging passed after those fixes.
The final standalone adapter executed all 134 test bodies with zero assertion failures, including a new repeated-output-switch regression covering each device's rate and the original route.
The local XCTest framework and follow-up CI limitations described above still apply.

The recorded baseline was WALKMAN as default output at 192 kHz with stereo 32-bit signed integer physical format, eight bytes per frame, flags 12, and no Hog Mode owner.
Manual 48 and 96 kHz selections reached those rates while retaining the unknown source's existing 32-bit representation.
The explicitly labeled Spotify profile reached 44.1 kHz without claiming track-format detection or playing subscription audio.
Independent CoreAudio readbacks after ordinary disconnects confirmed exact restoration of the original rate and representation.

An owned five-second 48 kHz / 24-bit ALAC reference in Music matched on its first playback.
The native panel showed Matched with 24-bit source evidence, and independent CoreAudio readback showed 48 kHz, stereo 24-bit signed integer, six bytes per frame, and flags 12.
Disconnect restored the original 192 kHz / 32-bit integer representation.
The particular source-evidence label was not captured during this brief playback, so this result does not establish whether decoder evidence or the local header caused the match.
The library entry and Music-managed copy were removed, and the filtered library showed no remaining test item.
The original generated WAV and ALAC fixtures were preserved locally.

Changing the rate to 48 kHz outside filo while it managed a manual 96 kHz target stopped the connection and preserved 48 kHz.
Connection details explicitly explained that the external rate was preserved.
The test operator then restored the recorded 192 kHz baseline.
Selecting MacBook Pro Speakers and then WALKMAN while connected changed the actual default output and retained the selected rate display without resizing the panel.

All four scene families, the matched studio state, details, settings, About, long output names, and the connected/disconnected menu-bar item were inspected in native captures.
The fixed 340 × 300 point content bounds were consistent across the captured pages and scenes.
The approved mockup and native matched state were compared at a normalized panel width in the [menu bar design QA record](validation/menu-bar-design-qa.md).

Short closed-panel idle samples showed the main process at 0.0% CPU in disconnected, Spotify-connected, and Music-connected states.
Spotify's helper reported 0.1% CPU; Music's two metadata helpers together reported 0.2-0.3%, with a further 0.9-1.2% for its decoder log observer.
These brief no-playback samples on a busy desktop are not sustained-performance or battery measurements.
Raw local receipts, screenshots, and generated fixtures are retained under the ignored `work/liquid-glass` directory.
The new checks verify host-side physical-format negotiation and restoration, not subscription source identity, gapless transitions, or samples received inside the Sony receiver.

## 1.1.0-beta.3 rejected-input diagnostics

Beta.3 adds default-off `verify-reference --inspect-rejection` diagnostics for owned test references.
It retains exact Float32 bits from at most 8192 stereo frames of the first rejected input callback, with no change to strict transport or comparison criteria.
The normal application leaves diagnostic capture disabled.
On the connected NW-ZX706, a Spotify first-start trial retained a changed 512-frame window and failed; the same-file repeat passed all 220,500 frames and 1,764,000 output bytes.
An offline exponential gain model reproduced every retained word, without identifying the responsible player or system component.
See the [onset investigation](research/spotify-onset-observation.md) for receipts, controls, restoration, and the separate BlackHole loopback-level confound.
These results do not resolve arbitrary first-play behavior or verify the Sony USB receiver.

## Post-beta.2 connected Spotify references

After reconnecting the NW-ZX706, one-run measurements connected Spotify 1.3.0.277 through BlackHole and filo's exclusive relay to the actual WALKMAN integer output callback.
Repeated playback of the original FLAC and WAV fixtures preserved all 220,500 stereo frames and 1,764,000 signed32 bytes exactly, with silent margins and zero reported buffer, timestamp, or cleanup errors.
New FLAC and ALAC selections also passed after BlackHole remained the default route between trials.
Other selections, including the first held-route trial, triggered representation fault 5 before a complete reference anchor reached the output capture.
Both an unmuted-tap control and a fixed-clock first-switch control also failed, so neither change alone resolves the observed failure.
Route and player history remain relevant uncontrolled state; the observations do not identify the responsible internal component or establish a generally reliable workaround.
The [connected observation](research/spotify-exclusive-observation.md) records positive and negative receipts, run order, binary identities, settings, and the measured boundary.
The production implementation and shipped beta.2 application remain unchanged.
These conditional local-file measurements do not verify subscription masters, arbitrary track transitions, USB payloads, or samples inside the DAC.

## Post-beta.2 Spotify local references

Spotify 1.3.0.277 preserved the complete original five-second 44.1 kHz, stereo 24-bit reference through a process-specific BlackHole tap for WAV, ALAC, and FLAC.
All three runs compared 220,500 frames and 441,000 Float32 words with zero differences, missing endpoints, or extra nonzero material.
Independent manual RIFF decoding and whole-sequence byte comparison confirmed each result, with ten positive and negative controls.
The [Spotify observation](research/spotify-reference-observation.md) links receipts, exact helper and analyzer sources, fixture hashes, settings, and restoration details.
These runs used no exclusive relay or physical DAC; WALKMAN was disconnected.
They establish a local reference at the named software boundary, not subscription-master identity or end-to-end receiver delivery.
The shipped beta.2 application is unchanged.

## Post-beta.2 player API comparison

The same complete ALAC reference passed an independent AVAudioPlayer-to-BlackHole process-tap test with rate adjustment disabled.
All 220,500 stereo frames matched exactly, with silent prefix and tail and no samples outside the 24-bit grid.
Enabling rate adjustment while retaining `rate = 1` changed samples and failed the strict reference comparison.
Both runs completed and restored the independently observed device, format, and clock baseline.
A third run connected the neutral ALAC player through filo's exclusive bridge to the actual WALKMAN software output callback.
Its [receipt](validation/avplayer-exclusive-reference.json) records all 220,500 reference frames and 1,764,000 signed32 bytes exactly, with zero byte, buffer, timestamp, or cleanup errors and verified restoration.
This measures the combined decoder-to-output chain in one run; it does not infer that result from separate segment tests.
This localizes the previous Music failure without identifying its internal cause, and does not add a DAC-receiver or subscription-master guarantee.
See the [player API comparison](research/player-api-reference-observation.md) for controls, receipts, and evidence boundaries.
The shipped beta.2 application is unchanged.

## 1.1.0-beta.2 recovery correction

Beta.2 corrects the `verify-reference` laboratory command's cleanup ordering on an operating-system failure to release an exclusive callback or restore its settings.
Both normal completion and deferred error cleanup now use one path that restores the media route only after exclusive cleanup returns no errors.
An incomplete release retains the virtual route and recovery journal so a later process can retry safely.
The native application and finite-reference harness already had this guard.
This correction does not change the measured PCM transport or turn the failed Music reference result into a pass.
Actual operating-system callback-destruction failure has not been injected on the physical device; the correction was verified by inspecting both command exits and strict compilation, with CI and packaged checks recorded in the release.

## 1.1.0-beta.1 validation record

Validation date: 2026-09-23.
The following measurements used development `arm64` laboratory builds on macOS 26.6.2, BlackHole 2ch, and a Sony NW-ZX706 exposed to the host as WALKMAN.
The earlier USB DAC mode assertion was a setup assumption; see the later [mode evidence correction](research/usb-dac-mode-correction.md), whose affected earlier interval is unknown.
They validate the tested exclusive transport to its physical-device callback boundary.
They do not establish whole-track identity through Apple Music or Spotify, or sample identity at the USB receiver.
CI and native packaged-app checks for commit `ff6be7c` passed the specific gates recorded below.
The final package was rebuilt after the error-description changes and checked separately below; the historical 1.0 checks remain separate evidence.

### Exclusive physical-output measurements

The new topology captures a separate BlackHole source and writes directly to the exclusively owned WALKMAN output.
Each short run requested eight seconds of quiet deterministic synthetic playback.
The long run requested 120 seconds.
The reference precision is 16 or 24 bits; the WALKMAN callback and physical stream used matching stereo 32-bit signed integer containers with non-mixable format flags `76`.
The comparator decoded the actual integer words written into the physical-device IOProc and compared their sample values with the deterministic reference.
It permitted one fixed startup offset and did not adjust gain, resample, or realign within the measured sequence.

| Source rate | Source precision | Requested duration | Compared stereo frames | Mismatched samples | Result and receipt |
| --- | ---: | ---: | ---: | ---: | --- |
| 44.1 kHz | 16-bit | 8 s | 354,816 | 0 | [Passed](validation/exclusive-44100-16-8s.json) |
| 44.1 kHz | 24-bit | 8 s | 359,424 | 0 | [Passed](validation/exclusive-44100-24-8s.json) |
| 48 kHz | 16-bit | 8 s | 389,632 | 0 | [Passed](validation/exclusive-48000-16-8s.json) |
| 48 kHz | 24-bit | 8 s | 389,632 | 0 | [Passed](validation/exclusive-48000-24-8s.json) |
| 96 kHz | 16-bit | 8 s | 769,024 | 0 | [Passed](validation/exclusive-96000-16-8s.json) |
| 96 kHz | 24-bit | 8 s | 773,120 | 0 | [Passed](validation/exclusive-96000-24-8s.json) |
| 192 kHz | 16-bit | 8 s | 1,533,440 | 0 | [Passed](validation/exclusive-192000-16-8s.json) |
| 192 kHz | 24-bit | 8 s | 1,526,272 | 0 | [Passed](validation/exclusive-192000-24-8s.json) |
| 192 kHz | 24-bit | 120 s | 23,034,880 | 0 | [Passed](validation/exclusive-192000-24-120s.json) |

All nine runs reported zero maximum integer error, underflows, overflows, invalid buffers, representation failures, missing timestamps, timestamp discontinuities, and latched faults.
Every run reported successful cleanup and independently checked restoration of the DAC's rate, physical and virtual formats, Hog Mode, default output, and the virtual clock selector.
The [matrix summary](validation/exclusive-matrix-summary.json) records the final baseline: WALKMAN default output at 192 kHz, physical flags `12`, virtual flags `9`, Hog Mode `-1`, and BlackHole at 44.1 kHz with its Internal Fixed clock.
The receipts contain statistics and configuration, without device UIDs or recorded music.
Their executable hashes describe the file present when each receipt was finalized; they are not an attestation of a loaded process image or the final packaged beta.

These synthetic checks establish an exact measured sequence at the callback boundary, not coverage of a finite music track from its first sample to its last.
The separate known-reference verifier requires full reference coverage and an independent output-byte comparison before reporting a whole-reference pass.
That stronger real-player result has not been obtained.

### Complete finite synthetic reference

A separate finite emitter stayed silent until the exclusive relay was armed, sent the original five-second 44.1 kHz / 24-bit fixture exactly once, and then continued with silent postroll.
The [whole-reference receipt](validation/exclusive-finite-reference-44100-24.json) records all 220,500 reference frames and 1,764,000 signed32 output bytes matching exactly at the WALKMAN output callback.
There were no missing opening or ending frames, byte mismatches, nonzero surrounding material, timestamp faults, or cleanup errors.
The expected and actual aligned byte hashes were both `8fd04325bfb401bac8d2700c967453319a12e7ead41dde6ee04505e64e118ea5`.
The independently checked post-run hardware matched the recorded baseline.
This result covers a complete synthetic reference through filo's measured output boundary; its source is the finite test emitter, not Music, Spotify, or the Sony receiver.
The receipt identifies the temporary helper and source hashes used in this run separately from the packaged application.
The [published laboratory wrapper](../scripts/verify-finite-reference.sh) repeated this complete-reference result after building from a fresh temporary directory; its [reproduction receipt](validation/exclusive-finite-reference-reproduction.json) records the published source hashes and restored hardware state.

### Actual process-crash recovery

The [crash-recovery receipt](validation/exclusive-process-crash-recovery.json) records a real interruption of the synthetic exclusive session, rather than a simulated journal test.
The identified test parent was stopped with `SIGSTOP` to prevent orderly cleanup from racing termination of its identified emitter child.
The child and parent were then terminated with `SIGKILL`; the parent exited with status `-9`.
No Music or Spotify process was terminated by this experiment.

Before interruption, the WALKMAN was held in Hog Mode at 44.1 kHz with physical and virtual flags `76`, and BlackHole used its Internal Adjustable clock at pitch `0.5032904`.
After both test processes exited, Hog Mode was released by process death, but the non-mixable formats and adjustable clock remained, and both output and clock recovery records still existed.
The default output at that point was BlackHole.
`filo-lab recover` returned no errors and restored the complete recorded baseline, including WALKMAN as default output, 192 kHz, physical flags `12`, virtual flags `9`, and BlackHole's Internal Fixed clock.
No recovery record or test-owned laboratory process remained after the final checks.

This verifies recovery from the tested process interruption on the connected devices.
It does not substitute for physical hotplug, sleep/wake, another application changing settings during recovery, or power-loss testing.
The journal uses atomic replacement for process-crash recovery and deliberately does not promise durable writes across power loss.
A pitch value hidden by BlackHole's original Fixed mode cannot be independently read or restored; the journal restores the original selector and all state that was observable when the lease began.

### Real-player reference investigation

Apple Music playback of the known five-second, 44.1 kHz / 24-bit ALAC fixture was measured at a process tap before the exclusive relay and physical DAC.
The fixture was tested both as a local HTTP resource and as an imported local file, after independently confirming that its ALAC decoding reproduced the generated reference.
After removing only surrounding silence, the two captured active spans were byte-identical to each other across 220,501 stereo frames and 1,764,008 bytes, with zero differing Float32 words.
That agreement is between the two transformed captures, not between either capture and the original reference.
Both contained 282,326 samples outside the 24-bit integer grid and the same altered opening lasting roughly 46 ms.
The steady portion had much smaller floating-point differences and rounded back to the original 24-bit sample values in offline analysis, but the production relay does not round them into a passing result.

This reproduces the source-path failure in both tested resource paths and does not support an HTTP-only explanation.
It does not identify the responsible Music or CoreAudio component or establish how other files and subscription playback behave.
See the [Music reference observation](research/music-reference-observation.md) and [sanitized numeric analysis](validation/music-reference-tap-analysis.json) for complete alignment, coverage, hashes, settings provenance, and error measurements.
No subscription recording or DRM extraction was involved.
No passing Apple Music or Spotify whole-track reference result, subscription-master comparison, USB payload capture, or DAC-receiver measurement is claimed for this beta record.

### Native packaged-app permission and failure checks

The packaged native app at commit `ff6be7c` was checked on the WALKMAN and BlackHole setup.
Exclusive preview displayed its microphone-permission waiting state while the hardware baseline remained unchanged, before taking the DAC or changing the source route.
Permission was subsequently granted externally, and the app progressed from waiting for Music to Armed at a manually selected 44.1 kHz.
Independent hardware inspection confirmed that the GUI process held WALKMAN Hog Mode with matching physical and virtual flags `76`, while BlackHole was the default output.

Playing the known generated reference then triggered representation fault `5`.
The app correctly disconnected instead of rounding the source samples, and restored WALKMAN as default output at 192 kHz with physical flags `12`, virtual flags `9`, and Hog Mode `-1`.
BlackHole returned to 44.1 kHz with its Internal Fixed clock.
This is a verified failure-and-restoration result, not a whole-track playback pass.
The task-owned GUI process and helpers were confirmed stopped after the check.

The user-approved test imports were removed from Music, and their absence was verified with a “No items” result.
The local generated fixture was retained.
Three byte-for-byte verified test copies left in Music's media folder were moved to Trash; the original project references remain available for reproducing the tests.

### Automated and final-package checks

Local strict compilation passed for the recovery implementation and its integration.
Eleven recovery test methods also passed through an independent assertion harness with fake hardware, covering pending writes, coupled format changes, external settings, UID-based reconnect resolution, foreign ownership, lock contention, and private journal files.
That harness result is not an XCTest or hardware-hotplug result.
The `BridgeTests.swift` Float inference fix passed strict type checking against the installed XCTest Swift overlay.

[GitHub Actions run 35882419650](https://github.com/Audiofool934/filo/actions/runs/35882419650) passed for commit `ff6be7c`, including 79 XCTest tests, strict compilation, and universal app packaging.
The native permission, arming, representation-failure, and restoration observations above apply to its packaged app.

The final app was rebuilt with the revised actionable representation-failure explanation.
Strict compilation passed, both app and laboratory executables contained `arm64` and `x86_64` slices, bundle metadata passed inspection, and deep/strict code-signature verification succeeded.
The exact revised explanation was confirmed in both packaged executable slices; the fault-and-restoration UI experiment above predates that wording-only change.
The rebuilt native window was opened and visually checked, displayed `1.1.0-beta.1` and WALKMAN at its restored 192 kHz, then exited cleanly.

The final packaged laboratory executable passed a separate eight-second 44.1 kHz / 24-bit physical-output check over 354,816 stereo frames, with zero sample errors, buffer faults, timestamp gaps, or cleanup errors.
Independent before/after hardware snapshots were equal.
The [package receipt](validation/exclusive-packaged-beta-44100-24.json) records both executable hashes and archive SHA-256 `1053c50b23422f7294152181e47f7a5a8d085d25e066ce9b003600744c610c1a`.
Final-revision CI is a separate release gate from these local packaged checks.
Hardware coverage remains limited to this Apple Silicon host and the NW-ZX706.
Physical Intel, other DACs, other macOS versions, real unplug/replug, and sleep/wake behavior remain unverified for the exclusive topology.

## 1.0 historical validation record

The 1.0 goal was an installable open-source menu bar companion for Apple Music and Spotify that keeps the existing players, automates output sample-rate management, and implements and measures the proposed relay before deciding how to expose it.
Its release gates required actual device readback, freshness checks on format evidence, lifecycle handling that restores only still-owned settings, no fabricated bit-perfect or bit-depth claims, deterministic PCM tests, real WALKMAN checks, and a reproducible public release.

Validation date: 2026-09-23.
Host: Apple Silicon MacBook Pro, macOS 26.6.2 (25G83), Swift 6.3.3, macOS 26.5 SDK.
Physical output: Sony NW-ZX706 exposed to the host as WALKMAN.
The earlier mode assertion is subject to the [USB DAC mode evidence correction](research/usb-dac-mode-correction.md); no affected interval has been assigned to this historical run.
Silent virtual output: BlackHole 2ch.
The release is universal; Intel execution was checked through Rosetta, not on a physical Intel Mac.

### Deterministic PCM measurements

| Experiment | Compared frames | Mismatched samples | Result |
| --- | ---: | ---: | --- |
| Tap input, 44.1/48/96/192 kHz × 16/24-bit, relay active | 2,266,624 | 0 | 8/8 passed |
| Rendered BlackHole digital loopback, same eight combinations | 2,285,056 | 0 | 8/8 passed |
| 60-second tap-input run, 44.1 kHz / 24-bit | 2,644,992 | 0 | Passed |
| 60-second rendered-loopback run, 44.1 kHz / 24-bit | 2,646,016 | 0 | Passed |
| WALKMAN tap input, relay active, 192 kHz / 24-bit | 381,440 | 0 | Passed |
| Universal binary's Intel slice under Rosetta, rendered loopback | 88,064 | 0 | Passed |

All successful runs reported zero invalid buffers and zero maximum integer sample error.
The matrix script restored BlackHole to its original 44.1 kHz setting.
The 60-second loopback and Rosetta runs used the packaged release binaries.
The WALKMAN run measured process-tap samples while forwarding to the device, not the final USB input.

Machine-readable synthetic reports are checked in under [validation/](validation/).
They contain format and comparison statistics, not audio recordings or device serial numbers.
The comparator allows a fixed startup offset, then compares all remaining frames without gain normalization, resampling, or midstream realignment.
See the [laboratory guide](LABORATORY.md#how-comparison-works) for the exact comparison rules.

The quiet synthetic patterns exercise many distinct sample values and channel positions.
They are not a full-amplitude hardware linearity test or an exhaustive enumeration of all 24-bit values through a DAC.

### Real player and native UI checks

- Apple Music subscription playback produced an observed 192 kHz / 24-bit lossless decoder format, and the app displayed source and output at 192 kHz.
- A naturally queued track transition from that 192 kHz track to a 44.1 kHz track caused filo to switch the WALKMAN to 44.1 kHz.
- A separate HAL read confirmed the changed physical device rate.
- Disconnect restored the WALKMAN to its original 192 kHz.
- Spotify's labeled 44.1 kHz profile changed the WALKMAN from 192 kHz to 44.1 kHz and restored it on disconnect.
- Spotify direct relay produced advancing callback/frame counters without invalid buffers on the WALKMAN.
- The native window, menu bar state, device/rate selectors, errors, details disclosure, scrolling, and quit flow were visually inspected.

These streaming checks establish operation and observed switching, not sample identity against subscription masters.
No subscription audio was saved as a test recording.

### Restoration and process lifetime

A packaged app connection changed the WALKMAN from 192 kHz to a manual 44.1 kHz setting.
The verified task-owned GUI process was deliberately terminated with SIGKILL.
Reopening the app restored 192 kHz from its journal and removed the recovery record.
The helper child from the terminated session also exited.

A second GUI test selected BlackHole and confirmed that it became the system default output.
An external laboratory command then changed BlackHole from 44.1 kHz to 48 kHz.
filo stopped the connection, preserved the externally selected 48 kHz, and restored the previous WALKMAN default output.
The test harness subsequently restored its own BlackHole change to 44.1 kHz.

Final hardware checks found WALKMAN as the default at 192 kHz, BlackHole at 44.1 kHz, and neither device held in Hog Mode.
Task-owned GUI instances, playback helpers, log streams, and emitters were stopped after testing.
No recovery journal remained.

### Automated and packaging checks

The XCTest suite contains 18 tests covering lossless PCM representation/copying, layout rejection, comparison corruption cases, decoder freshness/conflicts, downward rate transitions, conditional restoration, failed writes, device-ID reuse, and crash-journal ownership.
GitHub Actions runs the suite on macOS 15, builds with Swift warnings treated as errors, and packages a universal app.
The workflow verifies bundle metadata, code signatures, both executable architectures, and laboratory startup.
The release commit's result is available in [Actions](https://github.com/Audiofool934/filo/actions/workflows/ci.yml).

Local checks verified both `arm64` and `x86_64` slices, bundle version 1.0.0, deep/strict code-signature integrity, and invalid laboratory argument rejection.
Local XCTest was unavailable because the Command Line Tools installation lacks XCTest and the full Xcode installation requires user acceptance of its license.
No license agreement was accepted by the agent; XCTest evidence comes from GitHub CI.

### Known failures and unverified cases

Physical-output Hog Mode stopped callbacks in the tested process-tap/aggregate topology on both BlackHole and WALKMAN.
The failed WALKMAN experiment recorded zero callbacks and released ownership during cleanup.
Exclusive relay therefore remains a laboratory experiment and is not exposed as a working app option.

The OS also returned a bad-object error when reading the active sub-tap's drift-compensation property.
The configuration explicitly requests compensation off, but only the main-clock selection and matching formats are independently read back at startup.

The following are not certified by this release:

- Sample identity against Apple Music or Spotify subscription masters.
- The actual USB payload or DAC input, DAC filtering, and analog output.
- Local reference files decoded by the Music application itself.
- Every prebuffered/gapless transition or a stable Music diagnostic-log contract.
- Real unplug/replug, system sleep/wake, revoked-permission dialogs, and physical Intel hardware across supported OS versions.
- macOS 14.4 runtime behavior on physical hardware; it is the API/deployment minimum, while local interactive tests used macOS 26.6.2 and CI used macOS 15.

Device disappearance and restoration ownership have unit-test coverage; that does not substitute for physical hotplug testing.
Sleep cleanup and callback-stall handling are implemented but are not listed as completed physical-device experiments.
The 1.0 release builds were ad-hoc signed and not Developer ID notarized; notarization began with 1.1.2.
