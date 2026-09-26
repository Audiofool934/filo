# Spotify combined-OFF evidence

This bundle contains one known-reference direct-start trial with Gapless and Automix off while Crossfade remained off.
The [observation](../../research/spotify-effects-off-observation.md) states the result and its joint-intervention limits.
The result is a failed complete-reference comparison with the same retained onset, not a pass or an attribution to an individual setting.
Mode evidence relies on prior user confirmation during the session, with no new Sony receiver readback.

The [archive provenance](archive-provenance.json) identifies exact original receipt and wrapper copies and the two explicit public-analyzer adaptations.
The original task-only analysis remains unchanged in ignored work.
The public analysis differs from it only in analyzer hash and the context sentence stating that Crossfade was already off.

## Offline reproduction

Run from the repository root with a fresh output path:

```sh
python3 docs/validation/spotify-effects-off/analyze.py \
  --report docs/validation/spotify-effects-off/combined-off.json \
  --reference work/reference-server/filo-reference-44100-24.wav \
  --output work/spotify-effects-off-reproduced.json
cmp docs/validation/spotify-effects-off/independent-analysis.json \
  work/spotify-effects-off-reproduced.json
```

The analyzer imports the existing [tap-autostart audit helpers](../spotify-tap-autostart/analyze-receipts.py) and [strict reference/snapshot parser](../spotify-onset/analyze-rejected-reference.py).
The [preceding mode-confirmed receipt](../spotify-tap-autostart/false-mode-on-reference.json) and [frozen model result](../spotify-onset/spotify-rejection-onset-model-analysis.json) supply unchanged numerical comparison evidence.
All 441,000 reference integer samples are validated against the existing independent generator, in addition to checking file SHA-256.
No onset parameter or source offset is fitted.
If a supplied receipt reports a pass, a separate branch requires complete 220,500-frame and 1,764,000-byte coverage, exact alignment and hashes, zero missing endpoints, zero padding or extra audio, and no faults.
An absent rejection snapshot never implies success.
The analyzer exit code describes audit consistency, so the archived failed playback correctly yields a successful offline audit.

If the canonical WAV is absent, the existing fixture subcommand generates it without playback:

```sh
dist/filo.app/Contents/MacOS/filo-lab fixture \
  --file work/effects-off-reference.wav --hz 44100 --bits 24 --seconds 5
```

Use that new path as `--reference` above.
The required file hash is `43728e416e9d6c4b27f03a46aecc604e3353ee1d51dec8b0fcb2037a2f2cd58e`.
The [offline controls](offline-controls.json) cover complete-pass and rejection branches, wrong hashes, missing endpoints, changed onset, inconsistent offender metadata, deterministic reruns, and existing-output refusal.
Their historical control receipts are numerical checks, not additional combined-OFF live measurements.

## Live measurement provenance

The measured executable was the unchanged scratch build documented in the [tap-autostart bundle](../spotify-tap-autostart/README.md#recorded-live-build-and-command-provenance), pinned to commit `4e77ac5f65d98359fe8bec4c3c3cb118bae6e822` with only tap autostart changed from true to false.
The recorded binary SHA-256 is `817c8e525c860ecb7a9db5203c0e31941df98d97b1f143e7eed867c510408e0c`.
The original [run.py](run.py) snapshot ran from `work/spotify-effects-off/run.py`, using a 60-second capture under a 120-second process-group watchdog.
It is not runnable in place from the archive because it resolves paths relative to its original location.
Its effective command was:

```text
work/audioqueue-first-start-build/.build/arm64-apple-macosx/debug/filo-lab \
  verify-reference --device WALKMAN --source "BlackHole 2ch" \
  --reference CANONICAL_REFERENCE.wav --player com.spotify.client \
  --seconds 60 --inspect-rejection
```

The wrapper did not control Spotify, and separate UI timing recorded the operator's playback action after arming.
The [protocol](protocol.json), [restart amendment](restart-amendment.json), and process observations record why an initial setup process was replaced before the sole reference capture.
The UI and stderr timestamps describe observations, not the exact instants samples were rendered.
Live execution changes routing and exclusive access and requires separately prepared playback and restoration; the offline commands above do not execute it.
The user's chosen Crossfade, Gapless, and Automix settings must remain off.
The [restoration record](restoration.json) confirms those choices were preserved, other task-modified discovery/playback preferences were restored, and no capture process remained.
