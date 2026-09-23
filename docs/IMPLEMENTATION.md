# filo 1.0 implementation record

## Goal

Ship an installable open-source macOS menu bar companion for Apple Music and Spotify, with a GitHub repository and a tested 1.0 release.
Preserve the existing players, automate output sample-rate management, and implement and measure the proposed audio relay before deciding how to expose it.
Report source format, captured format, device format, and verification scope separately.

## Release gates

- Native menu bar app with source and output selection, actual device readback, clear connection state, and actionable errors.
- Automatic format management for Apple Music, with freshness and provenance checks, and an explicitly identified Spotify format policy.
- Investigate and implement process capture, no-DSP transport, and exclusive output with deterministic PCM measurements.
- Lifecycle handling for stop, quit, sleep, source exit, format changes, disconnect, and failed startup; restore only settings still owned by filo.
- No fabricated bit-perfect certification or source bit depth.
- Tests for PCM preservation, malformed formats, switching policy, stale events, errors, and restoration ownership.
- Real device checks on Sony WALKMAN and native UI inspection.
- Reproducible build, install instructions, privacy/permissions documentation, license, CI, versioned release assets, and public repository verification.

## Current evidence

2026-09-23: existing project contained research documentation only.
Swift 6.3.3 and the macOS 26.5 SDK are usable through the installed Command Line Tools.
Sony WALKMAN is the default output at 192 kHz; system sounds use the built-in speakers.
BlackHole 2ch is available for silent deterministic transport experiments.

## Implementation decisions

Use Swift Package Manager, native macOS UI, direct public CoreAudio APIs, and a small C real-time transport.
Use the MIT license for original implementation; do not incorporate GPL implementation code.
The realtime callback must not allocate, block, access files, or log.
Only synthetic test PCM may be saved by the laboratory tool; the app must not save captured music.
The release gate remains open until measured behavior and packaged runtime checks are recorded.
