# Menu bar implementation QA

Date: 2026-09-26.
Branch: `feat/liquid-glass-menubar`.

## Evidence

- Source visual truth: `work/liquid-glass/approved-design.png`, the user-approved studio mockup with the smooth header transition and details under the more menu.
- Source image dimensions: 1426 × 1103 pixels, including the surrounding desktop and menu bar.
- Intended native content viewport: 340 × 300 points, excluding the popover arrow and shadow.
- Intended state: Apple Music, 48 kHz / 24-bit, WALKMAN output, matched, light appearance.
- Implementation screenshot: unavailable because the Mac is locked and native UI automation cannot access it.
- Current physical output list: MacBook Pro Speakers and other virtual/HDMI outputs; WALKMAN is absent.

## Comparison status

No source-to-implementation comparison has been performed.
The source and four scene assets were opened and inspected, but asset inspection and successful builds do not establish native visual fidelity.
Pixel-density normalization, full-view comparison, and focused control/text comparison remain pending an actual native capture.
The first native capture must be cropped to the content region and compared with the corresponding mockup region at the same point size.
State differences must be recorded if the 48 kHz matched WALKMAN state is unavailable.

## Required fidelity surfaces

| Surface | Current evidence | Remaining verification |
| --- | --- | --- |
| Typography | Native system fonts and a compact system menu-bar font in code | Actual size, weight, legibility, truncation, and baselines |
| Spacing and layout | Fixed 340 × 300 point frame for all pages | Actual popover bounds, clipping, spacing, and constant height |
| Colors and materials | Native Liquid Glass on macOS 26, older-system material fallback, continuous artwork mask | Actual glass, contrast, dark appearance, and Reduce Transparency |
| Artwork | All four local assets visually inspected | Native crop, scaling, readability, and rate transitions |
| Copy and controls | Info button removed; details under the more menu; explicit Spotify profile and manual labels | Native interaction, keyboard access, and error states |

## Findings

No visual findings are asserted without a rendered implementation.
The blocking evidence gap is access to the unlocked native desktop.
Current successful build and software checks are recorded separately in `docs/CORE-FORMAT-MATCHING.md`.

## Implementation checklist

- Capture the running native panel after unlocking the Mac.
- Compare the main panel, header transition, status item, and source/output controls with the approved mockup.
- Exercise more menu, details/back, settings/back, app/output selection, the switch, Escape, and outside dismissal.
- Confirm the same content bounds across pages and rate scenes, including a long output name.
- Verify matching and restoration on the NW-ZX706 after reconnecting it in USB DAC mode.
- Measure closed-panel idle and connected behavior on the new app, then stop task-owned probes.

## Comparison history

No native comparison iteration has run; the desktop was locked before the new app could be launched.
The existing running app and its bundle were preserved.

final result: blocked
