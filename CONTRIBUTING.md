# Contributing to filo

Thanks for helping improve filo.
Bug reports, device reports, documentation fixes, and code are all welcome.
To report a vulnerability, follow the [private security process](SECURITY.md) instead of opening an issue.

## Requirements

- macOS with Xcode 26 or later, with its license accepted, for the macOS 26 SDK and XCTest.
  The Command Line Tools with the macOS 26 SDK can build the app but cannot run the tests.
- Python 3.10 or later for packaging and the laboratory scripts.
- [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole) for audio-path tests.

The native Liquid Glass APIs need the macOS 26 SDK at build time, while runtime availability checks keep the deployment target at macOS 14.4.

## Build, test, and run

```sh
swift build -Xswiftc -warnings-as-errors
swift test
bash scripts/build.sh
open dist/filo.app
```

`scripts/build.sh` assembles `dist/filo.app` for the current architecture; add `--universal` for an arm64 and x86_64 bundle.
It signs ad hoc unless `SIGNING_IDENTITY` names a certificate you intend to use, and signing alone does not notarize the app.
Quit any running copy of filo before replacing `dist/filo.app`.

CI runs the strict build, the XCTest suite, a hardware-free compile of the laboratory harness, and universal DMG and ZIP packaging on every pull request.
It has no DAC, music subscription, or audio-capture permission, so hardware behavior and the native UI need separate checks.

## Project layout

| Path | Contents |
| --- | --- |
| `Sources/FiloApp` | Menu bar app and SwiftUI card. |
| `Sources/FiloCore` | Connection state machine, device access, format detection, lease and recovery, relay sessions, and verification. |
| `Sources/FiloPCM` | C realtime audio callbacks. |
| `Sources/FiloLab` | The `filo-lab` command-line laboratory. |
| `Tests/FiloCoreTests` | XCTest suites using fake devices and fixtures. |
| `scripts/` | Build, packaging, release verification, and laboratory harnesses. |
| `docs/` | User, technical, and release documentation; see the [index](docs/README.md). |

[Architecture](docs/ARCHITECTURE.md) explains how the pieces fit together.

## Changing audio behavior

- Keep allocation, locks, file access, logging, and Swift runtime work out of the C audio callbacks.
- Reject unsupported layouts and unrepresentable samples explicitly; never insert conversion silently.
- Keep source format, observed tap format, physical output format, and verification evidence separate.
- Restore only settings filo still owns, and resolve devices by persistent UID.
- For format-matching changes, keep the [acceptance matrix](docs/CORE-FORMAT-MATCHING.md#acceptance-matrix) true and extend it for new cases.

For changes to the relay or bridge, run the silent loopback matrix with BlackHole installed:

```sh
swift build
python3 scripts/verify-pcm.py --loopback
```

Set BlackHole's gain to unity and mute off, note the original settings, and restore them afterwards.
Lower the listening level before any synthetic test on a physical device.
Never record or publish subscription audio as a test fixture.
The [laboratory guide](docs/LABORATORY.md) covers the exclusive-path and whole-reference tests.

## Documentation and evidence

- Write documentation, comments, interface text, and GitHub templates in English; the project keeps a single English documentation set.
- In Markdown, put each sentence on its own line.
- Describe what was measured and where the measurement stopped.
  Never describe a matching rate, a format label, or a clean callback as bit-perfect playback.
- Record new hardware results in [VALIDATION.md](docs/VALIDATION.md) with the revision, versions, and hardware, and commit receipts under `docs/validation/`.
  Receipts hold statistics and configuration, never recordings, device serial numbers, or private paths.
- Put investigations in `docs/research/` and add them to the research index.
- Keep captures, screenshots, and scratch output in the ignored `work/` directory.

## Issues

Include the macOS version, filo version, player, output model, selected audio path, reproduction steps, and a reviewed diagnostic summary from **••• → Connection details → Copy diagnostics**.
Leave out device serial numbers, private file paths, account details, and track titles unless they are necessary and intentionally shared.

## Pull requests

Open pull requests against `main`.
The `test` check must pass on an up-to-date branch, and review conversations must be resolved before a squash merge.
Releases follow [Distribution](docs/DISTRIBUTION.md).

Contributions are licensed under the project's [MIT License](LICENSE).
Keep source provenance clear, and do not copy code from projects with incompatible licenses.
