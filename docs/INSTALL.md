# Install filo

[Back to filo](../README.md)

## Download

Requires macOS 14.4 or later.
One download supports both Apple Silicon and Intel Macs.
Native Liquid Glass requires macOS 26; earlier versions use native material fallbacks.

1. [Download filo for Mac](https://github.com/Audiofool934/filo/releases/latest/download/filo-macos-universal.dmg).
2. Open the DMG and drag **filo** onto the **Applications** folder.
   When copying finishes, eject the filo disk image.
3. Open filo from Applications, then click **ƒ** in the menu bar.

There is no Dock icon or separate main window.
A [ZIP alternative](https://github.com/Audiofool934/filo/releases/latest/download/filo-macos-universal.zip) is also available; unzip it and move **filo.app** to **Applications**.
GitHub's **Source code** downloads are for building it yourself.
[Release notes and SHA256SUMS](https://github.com/Audiofool934/filo/releases/latest) are available alongside the app download.

## First launch

The 1.1.2 DMG and ZIP are signed with Developer ID and notarized by Apple.
Both include the app's notarization ticket, and the DMG has its own ticket.
macOS may still ask you to confirm opening an app downloaded from the internet; this is the normal first-launch confirmation described in [Apple's instructions](https://support.apple.com/en-us/102445).

If macOS cannot verify the developer, first check that you downloaded version 1.1.2 or later from this repository's releases; older versions were not notarized.
If a current release is blocked, or the message says the app is damaged or will harm your computer, stop and [report the exact message](https://github.com/Audiofool934/filo/issues/new/choose).

## Connect your music

1. Connect your USB DAC and enable its USB DAC mode if needed.
2. In filo, choose **Apple Music** and your DAC.
3. Turn on **Automatic** and allow playback access if macOS asks.
4. Start a lossless track in Music.

The default **Format matching** path needs Automation access to read the selected player's playback information.
It does not require BlackHole, a new audio driver, system-audio capture, or microphone permission.
Those additional dependencies belong to optional experimental paths in Settings.

For Spotify, choose **Spotify profile** for its fixed 44.1 kHz target.
Spotify's current track format is not detected automatically.

Enable lossless audio in the player separately if you want lossless playback.
filo does not change your player's quality, volume, or effects.

## If something looks wrong

- **Source format unknown:** start another lossless Music track; if detection remains unavailable, choose a known rate manually in Settings while disconnected.
- **No DAC listed:** check its USB connection and USB DAC mode.
- **After sleep or unplugging:** turn the connection back on.
- **Brief gap when the rate changes:** a DAC can pause while switching its hardware rate.

[Full usage and troubleshooting](USAGE.md) covers formats, permissions, and recovery.

## Update or remove

To update, disconnect and quit filo through **••• → Quit filo**, replace the app in Applications, reopen it, and reconnect.
Quitting releases the active connection and restores settings still owned by filo.

To remove it, quit the same way and move filo.app to Trash.
filo does not install a driver or administrator helper.
