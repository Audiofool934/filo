# filo 1.0 validation record

Validation date: 2026-09-23.
Host: Apple Silicon MacBook Pro, macOS 26.6.2 (25G83), Swift 6.3.3, macOS 26.5 SDK.
Physical output: Sony NW-ZX706 in USB DAC mode, exposed as WALKMAN.
Silent virtual output: BlackHole 2ch.
The release is universal; Intel execution was checked through Rosetta, not on a physical Intel Mac.

## Deterministic PCM measurements

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

## Real player and native UI checks

- Apple Music subscription playback produced an observed 192 kHz / 24-bit lossless decoder format, and the app displayed source and output at 192 kHz.
- A naturally queued track transition from that 192 kHz track to a 44.1 kHz track caused filo to switch the WALKMAN to 44.1 kHz.
- A separate HAL read confirmed the changed physical device rate.
- Disconnect restored the WALKMAN to its original 192 kHz.
- Spotify's labeled 44.1 kHz profile changed the WALKMAN from 192 kHz to 44.1 kHz and restored it on disconnect.
- Spotify direct relay produced advancing callback/frame counters without invalid buffers on the WALKMAN.
- The native window, menu bar state, device/rate selectors, errors, details disclosure, scrolling, and quit flow were visually inspected.

These streaming checks establish operation and observed switching, not sample identity against subscription masters.
No subscription audio was saved as a test recording.

## Restoration and process lifetime

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

## Automated and packaging checks

The XCTest suite contains 18 tests covering lossless PCM representation/copying, layout rejection, comparison corruption cases, decoder freshness/conflicts, downward rate transitions, conditional restoration, failed writes, device-ID reuse, and crash-journal ownership.
GitHub Actions runs the suite on macOS 15, builds with Swift warnings treated as errors, and packages a universal app.
The workflow verifies bundle metadata, code signatures, both executable architectures, and laboratory startup.
The release commit's result is available in [Actions](https://github.com/Audiofool934/filo/actions/workflows/ci.yml).

Local checks verified both `arm64` and `x86_64` slices, bundle version 1.0.0, deep/strict code-signature integrity, and invalid laboratory argument rejection.
Local XCTest was unavailable because the Command Line Tools installation lacks XCTest and the full Xcode installation requires user acceptance of its license.
No license agreement was accepted by the agent; XCTest evidence comes from GitHub CI.

## Known failures and unverified cases

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
