# filo

Your music. A direct connection.

filo is an open-source macOS audio companion project for connecting existing music applications to an external DAC.
The working name comes from the Italian word for “thread”.

## Status

The project is in feasibility research and design.
An audio engine has not yet been implemented or validated.
The name remains provisional pending a naming check.

## Intended experience

- Keep using Apple Music or Spotify.
- Choose a music application and an output DAC from a small menu bar app.
- Match the output format when the source format can be established reliably.
- Show the actual output state and the limits of verification.

The initial hardware target is a Mac connected by USB to a Sony NW-ZX706 in USB DAC mode.

## Engineering approach

Two capabilities are being evaluated: automatic output-format management and a sample-preserving audio relay using public CoreAudio APIs.
Exclusive output and matching sample rates are useful properties, but neither alone proves bit-perfect playback.

The first engineering milestone is a reproducible experiment comparing known PCM samples before and after capture, followed by DAC output and lifecycle testing.
Results must distinguish local-file playback, subscription streaming, the software relay, and the actual DAC input.

## Design document

[Feasibility, architecture, and validation plan (Chinese)](docs/feasibility.md)

## Open-source intent

The project is intended to be open source.
The code license will be selected before incorporating third-party code or publishing an implementation.
