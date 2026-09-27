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

The imported Music reference and its managed copy were removed after testing; the original generated fixture was subsequently moved to Trash during the [test-audio cleanup](docs/validation/test-audio-cleanup.md).
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

## 1.1.1 menu card follow-up

Date: 2026-09-27.
Branch: `codex/stable-menu-card`.
Scope: stabilize the menu item, give it a recognizable filo f, and remove the popover arrow.
The earlier captures above describe the previous UI.

The menu item now uses `NSStatusItem.squareLength` with an 18-point monochrome template image drawn from the app icon's curved f motif.
Connection and sample-rate changes no longer update the item's title or width.
An arrowless, nonactivating `NSPanel` replaces `NSPopover`, retaining the existing 340 × 300 point composition and clipping the glass and artwork to one continuous rounded outline.
The card is centered on the status button, constrained to its screen, and aligned to physical pixels when opened.
Only opening the card sets its position; connection updates do not reposition it.

### Native checks

- Reproduced the original off/on menu-item change in the released app before replacing it.
- Inspected the final card and details page visually in macOS 26 light appearance.
- Connected and disconnected with Apple Music selected and no music playing; the card changed between Ready to match and Waiting for music.
- Opened Connection details from the native more menu and returned with Back.
- Verified that Escape hides the card and reopening returns to the main page.
- Confirmed that off, on, and details captures are all 680 × 600 pixels at 2× scale.
- Inspected the actual vector icon rendered at 2× separately.
- Quit the final preview through its native Quit filo menu and verified process exit.

Local evidence is in the ignored `work/menu-card` directory: `before-off.png`, `before-on.png`, `final-off-native.png`, `final-on-native.png`, `final-details-native.png`, `f-monogram-2x.png`, and `delivered-ready-native.png`.
The hosting controller initially reset the panel to zero size; explicit content sizing after controller installation resolved this and was verified in the native captures.
The application-activation dismissal observer checks that the panel has lost key focus so native menu activation does not immediately dismiss the details page.

### Build and delivery

The final code passes a Swift build with warnings treated as errors and a universal release build.
Both delivered executables contain arm64 and x86_64 slices, the Info.plist passes lint, and the app passes deep strict code-signature verification.
The tested bundle is installed at `dist/filo.app` as 1.1.1, build 8, with a local universal ZIP and SHA-256 manifest.
The previous 1.1.0 bundle and ZIP are preserved under `work/menu-card`.
The delivered app was launched and inspected with Automatic, Apple Music, MacBook Pro Speakers selected, and the connection off.
No new public release was created for this follow-up.

The initial preview preserved the recorded default speakers route and its 48 kHz format.
The later independent readback found WALKMAN as the default at 192 kHz, with no Hog Mode owner and no connection journal.
There is no continuous route trace identifying when that changed, so this follow-up does not claim the original default route stayed constant for the entire session.
The observed final default was left untouched.
No audio-engine source changed.

### Coverage limits

Window captures verify content size, not absolute desktop coordinates.
The fixed menu-item width and the absence of state-driven positioning were checked in code; the actual F in the desktop menu bar and repeated same-icon toggling were not captured successfully by the native desktop-capture tool.
Outside-click, application-switch, screen-change, sleep, and Space-change dismissal are implemented but were not established end to end by this session's UI automation.
Dark appearance, older macOS versions, fullscreen behavior, and Intel execution were not rechecked.
The audio XCTest suite was not rerun for this UI-only patch; the release build and native interactions are the validation for this follow-up.

### Spacing refinement, build 9

The status item now has an explicit 20-point width instead of the system's square width, reducing horizontal padding around the unchanged 18-point f image.
Its width remains constant across connection states.
The refinement passes the warnings-as-errors and universal builds, and the updated local bundle passes strict signature verification.
Before updating, the native card showed an active Apple Music to WALKMAN connection; after the update those selections were retained and the connection was re-enabled.
The connection journal confirms the running delivered app owns the restored WALKMAN session.
The native automation intermittently lost the open card after restart, so the final matched source label and desktop menu-bar spacing were not captured in this follow-up.
The previous build 8 bundle and package are preserved in the ignored `work/menu-spacing` directory.

## More menu hit area, build 10

Date: 2026-09-27.
Branch: `codex/more-menu-hit-area`.
Reproduced the missed clicks in the running 1.1.1 build 9 card with ordinary pointer clicks, rather than accessibility activation alone.
At 2x scale, the ellipsis center at (624, 56) opened the menu, while (624, 44) and (624, 68), both inside its visible glass circle, did not.
The plain menu label lacked an explicit hit shape around its 24-point frame.
Adding `contentShape(Circle())` to that label makes its interaction area match the visible button without changing its size, appearance, audio behavior, or window dismissal.

The locally delivered 1.1.2 build 10 passed pointer checks at the top, bottom, left, right, and center: (624, 38), (624, 74), (606, 56), (642, 56), and (624, 56).
Escape closed the native menu between checks, and each subsequent single click reopened it.
Connection details and Settings opened from the menu and returned to the main card normally.
The bottom-edge check also passed with the connection enabled.
Escape from the main card left no visible filo window.
The original Spotify to WALKMAN connection was restored, displaying 44.1 kHz and Waiting for music with its switch on.
Local screenshots and pointer-check results are retained in the ignored `work/menu-hit-fix` directory.

The warnings-as-errors build and universal release build passed, as did deep strict signature and both-architecture checks.
Local XCTest could not compile because this computer has Command Line Tools without the XCTest module or a full Xcode installation.
This is a native pointer-interaction regression check on macOS 26 in light appearance, not a frame-time benchmark or a full accessibility audit.
The previous app bundle is preserved at `work/menu-hit-fix/filo-before-hit-area.app`.

## DMG distribution preparation

Date: 2026-09-27.
The 1.1.2 build 10 package now includes a DMG with the app, an Applications shortcut, and a light installation background containing a teal drag arrow.
The final image was opened through Finder and visually inspected on macOS 26 at Retina scale.
The two icons, their labels, the heading, and the drag instruction are visible and aligned.
Finder retains this user's tab and path bar preferences; those global settings were not changed.
The final native capture is `work/dmg-distribution/installer-final.jpg`.

The first package exposed a strict-signature failure because hiding the app's extension added FinderInfo to the already-signed bundle.
The packaging settings no longer modify the app's FinderInfo.
A separate Retina background issue was fixed by setting bitmap display size after rendering, avoiding a second scale transform.

Final packaging passed DMG checksums, ZIP checksums, app signature verification inside both artifacts, both CPU architecture checks, and byte comparisons of all bundled app files.
The verification also checks the Applications symlink and the Finder layout assets, then detaches its own mount.
Ad-hoc and Apple Development identities were rejected by the notarization preflight before building or uploading.
The running `dist/filo.app` and its existing connection were not replaced or restarted by packaging.
The preview mounts and temporary Finder windows were closed after inspection.

Only an Apple Development identity was available locally, so Developer ID signing, submission to Apple, ticket stapling, Gatekeeper acceptance, and a fresh-Mac installation remain unverified.
The new notarization workflow is opt-in, uses a named Keychain profile, and requires Apple's Accepted result before producing final release artifacts.
Dark appearance and earlier macOS Finder versions were not visually checked.

## Developer ID and notarization verification

Date: 2026-09-27.
The Developer ID Application certificate was issued and imported into the login Keychain, and its public key matches the locally generated certificate request.
The signing private key was not exported.
The app, nested laboratory executable, and DMG have valid Developer ID signatures and secure timestamps; the executable signatures enable Hardened Runtime.

The first run of the notarization path stopped before submission with exit status 141.
With `pipefail` enabled, `grep -q` could close the signature-details pipe before `codesign` finished writing.
The script now captures the complete signature details before checking the authority.
The subsequent real submission completed successfully.

Apple returned Accepted for both the application and DMG submissions.
Both tickets were stapled and validated, and Gatekeeper reported `source=Notarized Developer ID` for the application and disk image.
Final packaging verified checksums, strict signatures, both CPU architectures, matching app contents in the DMG and ZIP, the installation shortcut, and Finder layout assets.
The final ZIP was extracted separately, and its app passed ticket validation and Gatekeeper assessment again.
Submission receipts and verification logs remain local in the ignored `dist/notarization` and `work/developer-id-setup` directories.

The running app and music connection were not replaced or restarted.
All packaging mounts and temporary verification directories were cleaned up.
These checks establish signing, notarization, and Gatekeeper acceptance on the current Mac; a fresh installation and launch on a separate Mac or clean account remain unverified.
