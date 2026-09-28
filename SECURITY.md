# Security

## Supported versions

Security fixes target the latest stable release.
Install only the Developer ID signed, Apple-notarized packages from [filo's GitHub releases](https://github.com/Audiofool934/filo/releases/latest), and check them against the published `SHA256SUMS` if you like.

## Reporting a vulnerability

[Report a suspected vulnerability privately](https://github.com/Audiofool934/filo/security/advisories/new) through GitHub; please do not open a public issue.
Include the affected version, reproduction steps, and the potential impact.
Do not include passwords, signing keys, subscription audio, or unnecessary personal data.

Relevant areas include filo's AppleScript helper processes, its recovery records in `~/Library/Application Support/filo`, the audio device settings it changes, and the release packaging and signing.
[Architecture](docs/ARCHITECTURE.md#privacy-and-data) describes what filo stores and which permissions it uses.

## Other problems

For installation, permission, and playback issues, use the [public feedback form](https://github.com/Audiofool934/filo/issues/new/choose).
