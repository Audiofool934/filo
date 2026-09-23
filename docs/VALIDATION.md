# filo validation record

## 1.1.0-beta.1 validation record

Validation date: 2026-09-23.
The following measurements used development `arm64` laboratory builds on macOS 26.6.2, BlackHole 2ch, and a Sony NW-ZX706 in USB DAC mode, exposed as WALKMAN.
They validate the tested exclusive transport to its physical-device callback boundary.
They do not establish whole-track identity through Apple Music or Spotify, or sample identity at the USB receiver.
Final beta CI, packaged-app validation, and native UI evidence are pending and must be recorded separately from the historical 1.0 checks below.

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

A pre-relay check of Apple Music playing a known ALAC reference over local HTTP received samples outside the declared 24-bit integer grid.
That attempt failed before it could establish preservation through the exclusive relay.
It is a failed source-path result, not evidence of a successful whole-track comparison or a diagnosis of which upstream component changed the samples.
Further source-path investigation remains open.
No passing Apple Music or Spotify whole-track reference result, subscription-master comparison, USB payload capture, or DAC-receiver measurement is claimed for this beta record.

### Automated checks and remaining release gates

Local strict compilation passed for the recovery implementation and its integration.
Eleven recovery test methods also passed through an independent assertion harness with fake hardware, covering pending writes, coupled format changes, external settings, UID-based reconnect resolution, foreign ownership, lock contention, and private journal files.
That harness result is not an XCTest or hardware-hotplug result.
The `BridgeTests.swift` Float inference fix passed strict type checking against the installed XCTest Swift overlay.

The 1.1.0-beta.1 CI result is pending.
A beta CI compile failure in an inferred floating-point test expression was corrected locally; the corrected commit still needs its own successful workflow result.
Final universal-package, native-window, and player lifecycle evidence must be attached for the beta rather than inferred from the 1.0 release.
Hardware coverage remains limited to this Apple Silicon host and the NW-ZX706.
Physical Intel, other DACs, other macOS versions, real unplug/replug, and sleep/wake behavior remain unverified for the exclusive topology.

## 1.0 historical validation record

Validation date: 2026-09-23.
Host: Apple Silicon MacBook Pro, macOS 26.6.2 (25G83), Swift 6.3.3, macOS 26.5 SDK.
Physical output: Sony NW-ZX706 in USB DAC mode, exposed as WALKMAN.
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
See [ARCHITECTURE.md](ARCHITECTURE.md) for the exact boundaries.

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
Release builds are ad-hoc signed and are not Developer ID notarized.
