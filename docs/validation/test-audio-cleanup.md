# Local test-audio cleanup

Date: 2026-09-27.

At the user's request, 11 generated test-audio files totaling 12,660,859 bytes were moved to macOS Trash.
Each original path is absent, and every recoverable Trash copy was checked against its original SHA-256.
The local recovery manifest is `work/test-audio-cleanup/completed.json` and is ignored by Git.

The removed files were the canonical five-second 44.1 kHz / 24-bit WAV, its HTTP-server WAV and ALAC copies, five Spotify codec and silence-control fixtures, one tap-autostart WAV copy, and the two 48 kHz menu-bar QA files.
No tracked test code, generator, reference hash, measurement receipt, raw capture, or application resource was removed.
Historical investigation notes describing locally retained source fixtures precede this cleanup.

Apple Music's Library search for `filo` returned no results, and its prior listening view was restored.
Spotify's Show Local Files setting was already off.
Spotify still held the tap-autostart WAV open, so it was quit normally before disposal and reopened afterward.
No audio sample was played as part of cleanup.

For future validation, `filo-lab fixture --file PATH --hz 44100 --bits 24 --seconds 5` regenerates the canonical WAV.
The existing `scripts/verify-finite-reference.sh` generates and removes its own temporary reference when `--reference` is omitted.
The silence-control generator remains in `docs/validation/spotify-prewarm/make-onset-fixtures.py`.
