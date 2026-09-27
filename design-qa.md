# Menu bar implementation QA

Date: 2026-09-27.
Branch: `feat/liquid-glass-menubar`.
Environment: macOS 26.6.2, Apple Silicon, light appearance, Sony NW-ZX706 in USB DAC mode.

## Evidence and comparison method

The approved source is `work/liquid-glass/approved-design.png`, the studio mockup with the smooth header transition and details under the more menu.
The actual matched capture is `work/liquid-glass/automatic-48000-native.png`, taken during first playback of an owned five-second 48 kHz / 24-bit ALAC reference in Apple Music.
Both show Apple Music, WALKMAN, 48 kHz, and Matched with 24-bit source evidence.
The source and implementation were inspected together, then cropped to their panel bodies and normalized to the same width in `work/liquid-glass/comparison-normalized.png`.
The mockup's original aspect ratio was preserved, rather than stretched to conceal the native panel's specified 340 × 300 point shape.
The mockup includes blue desktop tint; the native app capture has a pale capture backdrop, so a pixel color difference is not evidence of a material failure.
This is a native adaptation of the approved composition, not a claim of pixel-identical rendering.

All eight inspected main/page captures are 732 × 652 pixels including the popover arrow, surrounding padding, and shadow.
Their content body is 680 × 600 pixels at 2×, consistent with the fixed 340 × 300 point native frame.
The local evidence directory `work/liquid-glass` is ignored by Git.
Full desktop captures were kept outside the repository; only menu-bar crops were retained with the local QA evidence.

## Findings and fixes

| Finding in the native app | Change | Post-fix evidence |
| --- | --- | --- |
| Borderless menu styling flattened custom labels, hid chevrons, and changed icon sizing. | Plain button menu style preserves the custom glass labels. | Matched studio capture and all later scenes show the intended icons, chevrons, and more button. |
| Selector widths moved with the output name. | Give both selectors equal flexible width inside a fixed-height, full-width glass row. | WALKMAN and MacBook Pro Speakers retain the same row bounds. |
| Blank areas inside a selector did not reliably open its menu. | Give the complete label a capsule hit shape. | The final candidate opens both menus through their full control bounds. |
| A selector exposed duplicate accessibility menu controls. | Combine each label into one named accessibility element. | One Music app control and one Output control in the native accessibility tree. |
| Reopening the app reset an already-open details/settings page. | Keep an already-shown popover on its current page. | Details, Settings, and Back work through subsequent app observations. |
| Disconnect could look unchanged while restoration completed. | Publish a busy Disconnecting state before restoration. | Disconnect completes with restored output; the short transitional label was not captured separately. |

## Visual surfaces

| Surface | Result and evidence |
| --- | --- |
| Typography | Compact system text, readable rate/status hierarchy, no main-page logo or Info button; matched studio and all four scene captures inspected. |
| Spacing and layout | Consistent panel bounds on main, details, settings, and About; long output name truncates within its button and retains the full accessibility/help name. |
| Materials and transition | Native Liquid Glass controls and panel; continuous photo fade beneath the header with no explicit divider. Desktop tint remains environment-dependent. |
| Artwork | CD at 44.1, home studio at 48, tube hi-fi at 96, and horn-speaker reference system at 192 inspected in the actual panel. |
| Copy and controls | Automatic, Manual rate, and Spotify profile remain distinct; Matched appears with observed source evidence; external change shows Connection stopped with an explanatory details page. |
| Menu bar | Actual desktop crops show the small link icon alone when off and the system-sized 192 label when connected; the old oversized f label is absent. |

Scene captures are `cd-spotify-native.png`, `automatic-48000-native.png`, `hifi-96000-native.png`, and `reference-192000-native.png`.
Page and control captures are `details-native.png`, `settings-native.png`, `about-native.png`, and `long-output-native.png`.
The stopped external-change state is recorded in `external-rate-native.png` and `details-external-native.png`.
The menu bar crops are `menu-bar-connected-native.png` and `menu-bar-off-native.png`.

## Interaction and hardware checks

- The switch connects and disconnects; the more menu opens Connection details, Settings, and About in place; Back returns to the main page.
- Source and output menus open through their labels; Return activates selected native menu items.
- Connected output changes to MacBook Pro Speakers and back to WALKMAN update both the UI and the actual default output.
- Native popover cancellation dismisses the panel; the desktop capture confirms no standalone window.
- The automatic Music reference changes WALKMAN to 48 kHz / 24-bit integer, confirmed independently through CoreAudio.
- Manual 48 and 96 kHz and Spotify's fixed 44.1 kHz profile reach their targets.
- Disconnect after the automatic and fixed-profile checks restores the exact original 192 kHz / 32-bit integer representation.
- An external 48 kHz write while filo manages 96 kHz stops management and preserves 48 kHz; the test operator then restores the recorded 192 kHz baseline.

The imported Music reference and its managed copy were removed after testing; the original generated fixture remains in the local evidence directory.
These checks establish UI behavior and host device-format negotiation, not sample equality at the USB receiver.
The first final-cleanup readback found speakers as default, while WALKMAN's rate and depth were restored.
Its cause was not established.
A fresh repeat from a verified WALKMAN default exercised WALKMAN to speakers to WALKMAN, then quit; the lease recorded the correct original route and the final independent readback confirmed WALKMAN remained default at 192 kHz / 32-bit with no Hog Mode owner.
The preview and its monitoring helpers exited, and the connection journal was removed.
This repeat is a bounded passing observation, not an explanation of the earlier route discrepancy.

## Performance sample

Three short `top` samples at two-second intervals were recorded with the panel closed and no music playing.
After the first cumulative sample, the disconnected main process reported 0.0% CPU and 47-48 MB memory, with no player helpers.
The Spotify connection reported main-process 0.0% and helper 0.1% CPU, using approximately 38 MB and 9.5 MB respectively.
The Apple Music connection reported main-process 0.0%, two metadata helpers totaling 0.2-0.3%, and its decoder log observer 0.9-1.2% CPU.
Their reported memory was approximately 43 MB for the main process, 18.7 MB across metadata helpers, and 2.9 MB for the observer.
These are brief observations on a busy desktop, not a controlled battery, sustained playback, latency, or regression benchmark.
Receipts are `disconnected-idle-top.txt`, `connected-idle-top.txt`, and `apple-music-connected-idle-top.txt`.

## Remaining coverage limits

Dark appearance, Reduce Transparency, macOS versions before 26, and Intel execution were not visually exercised in this session.
Keyboard menu activation and native cancellation were checked, but this is not a complete VoiceOver or keyboard-only accessibility audit.
The source-detection limitations and XCTest toolchain limitation are recorded in `docs/CORE-FORMAT-MATCHING.md`.

## Local delivery

The tested executable bytes and four scene assets were copied into `dist/filo.app`, verified, and packaged as `dist/filo-1.1.0-beta.5-macos-universal.zip` with a SHA-256 manifest.
Both executables contain arm64 and x86_64 slices, and the bundle passed strict signature verification and plist lint.
The delivered app was launched and captured in `delivered-ready-native.png`, showing Automatic, Apple Music, WALKMAN, and Ready to match with the switch off.
It remains running for the user; all test previews and their helpers were stopped.
The previous beta.4 app is preserved under `work/liquid-glass/filo-beta4-before-menu-bar.app`.

final result: pass for the inspected native light-mode surfaces and recorded WALKMAN scenarios
