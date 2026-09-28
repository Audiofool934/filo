# filo documentation

[Back to filo](../README.md)

## Using filo

| Document | What it covers |
| --- | --- |
| [Install](INSTALL.md) | Requirements, download, first launch, updating, and removing filo. |
| [User guide](USAGE.md) | The card, statuses, settings, automatic detection, permissions, recovery, and troubleshooting. |
| [Exclusive preview](EXCLUSIVE-PREVIEW.md) | The experimental exclusive output path, its requirements, and what has been measured. |

## How filo works

| Document | What it covers |
| --- | --- |
| [Architecture](ARCHITECTURE.md) | Processes, control flow, format evidence, the three audio paths, recovery, privacy, and measurement boundaries. |
| [Core format matching](CORE-FORMAT-MATCHING.md) | The behavior contract and acceptance matrix for the default path. |
| [Validation](VALIDATION.md) | What has been tested, on which hardware and revisions, and what remains unverified. |
| [Audio laboratory](LABORATORY.md) | The `filo-lab` tool and how to reproduce the PCM measurements. |

## Contributing and releasing

| Document | What it covers |
| --- | --- |
| [Contributing](../CONTRIBUTING.md) | Building, testing, project conventions, and pull requests. |
| [Distribution](DISTRIBUTION.md) | Developer ID signing, notarization, and publishing a release. |
| [Security](../SECURITY.md) | Reporting a vulnerability privately. |

## Records

- [`releases/`](releases/) holds the published release notes.
- [`research/`](research/) holds dated investigations, starting with the original [feasibility study](research/feasibility.md); the [validation record](VALIDATION.md#research-index) indexes them.
- [`validation/`](validation/) holds machine-readable receipts, analysis scripts, and QA records such as the [menu bar design QA](validation/menu-bar-design-qa.md).

Research and validation records are historical: each describes what was true for the revision and setup it names.
