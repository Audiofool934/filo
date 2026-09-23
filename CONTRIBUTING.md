# Contributing to filo

Use a current Xcode installation with the license accepted and a macOS SDK supporting process taps.
The minimum deployment target is macOS 14.4.

```sh
swift build -Xswiftc -warnings-as-errors
swift test
bash scripts/build.sh
```

For a universal bundle, run `bash scripts/build.sh --universal`.
By default, packaging ad-hoc signs the app and its laboratory executable.
Set `SIGNING_IDENTITY` only when you have an appropriate signing identity and intend to use it.
Signing does not itself notarize the app.

For audio-path changes, install BlackHole 2ch separately and run the silent matrix:

```sh
python3 scripts/verify-pcm.py --loopback
```

The script restores the virtual device's original rate if it still owns the last rate it set.
Do not use a physical listening device for synthetic testing without reducing the listening level.
Do not record or publish subscription audio as a test fixture.

Keep allocation, locks, file access, logging, and Swift runtime work outside the C audio callback.
Reject unsupported layouts explicitly rather than silently inserting conversion.
Keep source format, observed tap format, physical output format, and verification evidence separate.
Document the measurement boundary whenever describing exact PCM preservation.

Include the macOS version, filo version, source app, output model, selected path, reproduction steps, and a reviewed diagnostic summary with an issue.
Do not include device serial numbers, private file paths, account details, or track titles unless necessary and intentionally disclosed.

The automated CI covers builds, XCTest policies and PCM tests, and app packaging.
It does not have a real DAC, a Music subscription, or audio-capture permission.
Hardware and native UI validation therefore remain separate evidence.

Contributions are licensed under the project's MIT license.
Keep source provenance clear and do not copy incompatible licensed implementations.
