# Spotify reference helper build and preflight

This archived build record accompanies the [frozen helper](inspect-spotify-reference.swift) and [reproduction instructions](README.md).
Its original local record had SHA-256 `4741041ca0d9a9f1bb8281888d196da01472cc43d41030812fd871fd4af81f01`; this copy adds archive navigation and relative source links while preserving every recorded hash and command.

This is a task-only source inspection helper, not application code or a supported playback feature.
The build and validations below did not launch Spotify, query HAL, change routing, or play or capture audio.
The original preflight failed before `REFERENCE_VALIDATED` and before any audio-device action.
Offline validation reproduced the same `Foundation._GenericObjCError error 0` for WAV, ALAC, and FLAC when making an additional one-frame read after all 220,500 valid frames had already decoded and matched.
The fix removes that extra EOF read and instead requires the checked declared length, exact consumed sample count, final frame position equal to file length, and an unchanged file hash.
All three native AVAudioFile decodes passed after this fix; no afconvert fallback or format-dependent relaxation was used.

## Source and executable identity

- [Archived source](inspect-spotify-reference.swift) SHA-256: `88c72bf62dbc462c23e71b005e4c3b4a18afbc96739d78d4f7e04dbe1c364ab1`.
- Compiled executable SHA-256: `4ddcc744b8b69b0d78cb206f05f31dbf08038da63a0996365ffeed10c63ad655`.
- Earlier failing source, retained locally as `work/inspect-spotify-reference-preflight-baseline.swift` and not included in this archive: `5e1af17e657cc6d1619f7be5c261b3d394cc3769f47ddaf9c118675c528a7f2a`.

## Compile command

The exact successful command used existing package objects, with optimization and warnings treated as errors.
The command did not rebuild the package objects, so their hashes are recorded separately from their current source files.

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools /usr/bin/swiftc -O -warnings-as-errors -target arm64-apple-macosx14.4 -I .build/arm64-apple-macosx/debug/Modules -I .build/arm64-apple-macosx/debug/FiloPCM.build work/inspect-spotify-reference.swift .build/arm64-apple-macosx/debug/FiloCore.build/*.swift.o .build/arm64-apple-macosx/debug/FiloPCM.build/*.c.o -o work/inspect-spotify-reference
```

The SDK version reported after compilation was `26.5`.

```text
Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)
Target: arm64-apple-macosx26.0
```

## Offline fixture validation

Each command below returned exit status 0, `passed: true`, 220,500 compared stereo frames, 441,000 compared samples, and zero differing Float32 words.
The `--validate-only` branch returns before signal setup, DeviceLease construction, recovery, process discovery, or capture.

```sh
work/inspect-spotify-reference --known-synthetic-only --format wav --validate-only
work/inspect-spotify-reference --known-synthetic-only --format alac --validate-only
work/inspect-spotify-reference --known-synthetic-only --format flac --validate-only
```

| Codec | File SHA-256 | Compared samples | Mismatched Float32 words |
| --- | --- | ---: | ---: |
| WAV | `43728e416e9d6c4b27f03a46aecc604e3353ee1d51dec8b0fcb2037a2f2cd58e` | 441000 | 0 |
| ALAC | `add662b2c40a791ddd0e406ad638848b58254fc4c4a0220f78e36d4b84510022` | 441000 | 0 |
| FLAC | `b47dc3336055c61a5e6ac442e64f6811a5f44ce2fe61790e0d55cc214f22a352` | 441000 | 0 |

The expected canonical Float32 sample-byte SHA-256 is `f8277734d6e03b38d497bc2397fed81e470cec581a9c564081d7a1db412ae428`.

## Hardware command for the operator

This command is documented only; the build/preflight agent did not run it.

```sh
work/inspect-spotify-reference --known-synthetic-only --format flac --seconds 30 --label first
```

After `READY_ARMED`, the operator plays only the selected original synthetic file once in Spotify.
The helper captures only `com.spotify.client` on BlackHole at 44.1 kHz with `relay: false` and leaves physical DAC output unopened.
It recovers exclusive endpoint journals before the ordinary route journal, captures a bounded window, stops tap IO before restoring its route lease, and refuses to overwrite any result.
Its report makes callback timestamp continuity unavailable because AudioSession exposes no such counters.
AudioSession also does not expose the stop/destroy OSStatus values to this helper, so the route restoration result is not proof of independently confirmed callback teardown.
No streaming master or USB receiver is observed.

## Linked object hashes

| Object | SHA-256 |
| --- | --- |
| `.build/arm64-apple-macosx/debug/FiloCore.build/AudioHardware.swift.o` | `83ad3ae1d2e57cd13e356a3ab0d98721537609666811574f29a066d81df069c2` |
| `.build/arm64-apple-macosx/debug/FiloCore.build/AudioSession.swift.o` | `0d1354a3498486ff8eae82b3156a4bf6cff536e9272433290fcbcf7b6a158f9b` |
| `.build/arm64-apple-macosx/debug/FiloCore.build/ClockFollower.swift.o` | `63a79f221604bf58e83003e72d11a618b86f02a6b6769005f457d9b0f5c17139` |
| `.build/arm64-apple-macosx/debug/FiloCore.build/ConnectionController.swift.o` | `070fdc3e25ea840c5f9fddf2e4b21f7bbd88d67934dadf15ec448ab18d6bdde8` |
| `.build/arm64-apple-macosx/debug/FiloCore.build/DecoderMonitor.swift.o` | `4fcfc72ef6e77caa3f22e1ef190ee016fc0b203de6dc39ba5ec54a8ccfcb0687` |
| `.build/arm64-apple-macosx/debug/FiloCore.build/DeviceInspection.swift.o` | `9bda3d264b740b353bc9ca511702b369073abbd201d378c352225b1eb91cca0e` |
| `.build/arm64-apple-macosx/debug/FiloCore.build/DeviceLease.swift.o` | `a54ff1bf76b6a3cd0541485026c9b9a8efa45c504ef962aeeb9a675a1f1b1a50` |
| `.build/arm64-apple-macosx/debug/FiloCore.build/ExclusiveDevice.swift.o` | `c6d2fab93955c49a11849714d0dbaeaf1b1acddd3c1c90e342ad52db67f74df0` |
| `.build/arm64-apple-macosx/debug/FiloCore.build/ExclusiveRecoveryJournal.swift.o` | `13a28cc1a6348e602792ead247539c58e4df50ddc2c868e82d3fa81dc354ff92` |
| `.build/arm64-apple-macosx/debug/FiloCore.build/ExclusiveRelaySession.swift.o` | `085cf6e90976ab0ddaf8af542af025fcad925dd230979d8c7935d0989dd303de` |
| `.build/arm64-apple-macosx/debug/FiloCore.build/FormatPolicy.swift.o` | `5ac375720b69f511cdcc986bd887d450ce6e83b0c12fd6070a705ca3b8e90f0d` |
| `.build/arm64-apple-macosx/debug/FiloCore.build/OutputByteVerification.swift.o` | `e4bbb82e7254ed87dd4bebc59c0c25110435a044366c32273473c6be178da696` |
| `.build/arm64-apple-macosx/debug/FiloCore.build/PCMVerification.swift.o` | `b6dd55a55b3048c6600e06e0ab4b61eb30709108b7ed9f751ce24ea71f80dec2` |
| `.build/arm64-apple-macosx/debug/FiloCore.build/PlayerReader.swift.o` | `3c5e1cfdb8133c7162c4d1b9caf72c5b0f44f652aa1ac266de0f2653533d1b76` |
| `.build/arm64-apple-macosx/debug/FiloCore.build/ReferencePCM.swift.o` | `f35b617188e3cc878e3746aeaff51a532f91adfc4d5fb2057a5780180d6db363` |
| `.build/arm64-apple-macosx/debug/FiloCore.build/SourceProcessingAssessment.swift.o` | `256565cd5045e193397a34dd78650ae57f908d194a089d147027cb701baf603e` |
| `.build/arm64-apple-macosx/debug/FiloCore.build/VirtualClock.swift.o` | `49bc848770db4f701fa7d7191c9a362f637e07ff1d39bc3cf09937b1594a27df` |
| `.build/arm64-apple-macosx/debug/FiloPCM.build/Bridge.c.o` | `2daade314cb9759dcc0cb726b7f7a6392261fe6b1a2ee2c0dbd916882caf7fda` |
| `.build/arm64-apple-macosx/debug/FiloPCM.build/Transport.c.o` | `3726bf27285dcfef44b7cf1408de6196d42f0041aaca71a5c4174a828ca26126` |

## Current production source hashes

These source hashes supplement the exact linked object identities; they are not a reproducible-build attestation.

| Source | SHA-256 |
| --- | --- |
| [Sources/FiloCore/AudioHardware.swift](../../../../Sources/FiloCore/AudioHardware.swift) | `89ff1233f8949eef496ee5571ce5bfc5263412d6cf500803dd838117d5ca904e` |
| [Sources/FiloCore/AudioSession.swift](../../../../Sources/FiloCore/AudioSession.swift) | `2e741749cc1ff55c0cc77c1ddb17fb7d16fd1ad406c69b604fa188af0de9c83a` |
| [Sources/FiloCore/ClockFollower.swift](../../../../Sources/FiloCore/ClockFollower.swift) | `a5eda8344a83cd00da6e983e9a0a6e06ae69d16ca26424af3432c7ce32d74250` |
| [Sources/FiloCore/ConnectionController.swift](../../../../Sources/FiloCore/ConnectionController.swift) | `ff17c6f9b95913366deef3c4415e26267aeb91c43160b153e32b96378430ffde` |
| [Sources/FiloCore/DecoderMonitor.swift](../../../../Sources/FiloCore/DecoderMonitor.swift) | `509e217b5207bc13a5f23f9f5b9eca11c6e9f82ad1690bf20cb2eaddab88cafa` |
| [Sources/FiloCore/DeviceInspection.swift](../../../../Sources/FiloCore/DeviceInspection.swift) | `5a46875b4a6c2574e0cbdbaffca69d23e5ffd30c06b645dba99f1824cc235e66` |
| [Sources/FiloCore/DeviceLease.swift](../../../../Sources/FiloCore/DeviceLease.swift) | `8bc34b208781001b8ee653fa1562f1bade39ac55207123beff8a88a8446b24a5` |
| [Sources/FiloCore/ExclusiveDevice.swift](../../../../Sources/FiloCore/ExclusiveDevice.swift) | `6ab664f2240bd10c838d5a98eb3d6ace056e03f0e9cfd1f5c8029511d34cf3d1` |
| [Sources/FiloCore/ExclusiveRecoveryJournal.swift](../../../../Sources/FiloCore/ExclusiveRecoveryJournal.swift) | `0d0a99a97d7db2c2f7c1eb14968833b05ed94fbce70a278a32d53cce54a518cf` |
| [Sources/FiloCore/ExclusiveRelaySession.swift](../../../../Sources/FiloCore/ExclusiveRelaySession.swift) | `80fe18d0affc6b020fa7db71fb8d15a595ffe27fe171175fd46027ef7b1e6b87` |
| [Sources/FiloCore/FormatPolicy.swift](../../../../Sources/FiloCore/FormatPolicy.swift) | `85fd448a6bcdd32ddc5e83fb6a5fabd7b86231fadf27ade5ff7bc2bd1112f8b7` |
| [Sources/FiloCore/OutputByteVerification.swift](../../../../Sources/FiloCore/OutputByteVerification.swift) | `7196849b55289d1a6ce20b7b86f2e3ae0b7abfd9a7fdc16de0c7ca877ca51096` |
| [Sources/FiloCore/PCMVerification.swift](../../../../Sources/FiloCore/PCMVerification.swift) | `f6a19f13a18ae812ab719bae2f9ddd6c4e8f8e58b3d9ce7c951614f56ecd14e2` |
| [Sources/FiloCore/PlayerReader.swift](../../../../Sources/FiloCore/PlayerReader.swift) | `4affcf4cd583288c656a37b3d9f79020ac7219f4c57355f724c1168336d73f48` |
| [Sources/FiloCore/ReferencePCM.swift](../../../../Sources/FiloCore/ReferencePCM.swift) | `95020aca10dad69a2b9a4f1f6e011f933b1f561f121593d85610a772a346aaf0` |
| [Sources/FiloCore/SourceProcessingAssessment.swift](../../../../Sources/FiloCore/SourceProcessingAssessment.swift) | `c99d6681a3dad5a86c7417e17922b65b3f7f2fd31254b2eb026d31e4828e331b` |
| [Sources/FiloCore/VirtualClock.swift](../../../../Sources/FiloCore/VirtualClock.swift) | `8438034a0193e1a649790d9cfcb4beff0b66b349d80a436a803a1b9ec461c826` |
| [Sources/FiloPCM/Bridge.c](../../../../Sources/FiloPCM/Bridge.c) | `3a534aa4776df70c45aab1c43a25e692bc014823fb5b8bd83f227372c873ed42` |
| [Sources/FiloPCM/Transport.c](../../../../Sources/FiloPCM/Transport.c) | `2fd436f0615c275b723f25b32b2090b9377fb16579d0fc100cf26d0344978161` |
