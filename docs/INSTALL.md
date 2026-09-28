# Install filo

[Back to filo](../README.md) · [User guide](USAGE.md)

## Requirements

- macOS 14.4 or later, on Apple Silicon or Intel.
  One universal download covers both.
- A USB DAC or other output device with one stereo output stream.
- Apple Music or Spotify.

Native Liquid Glass appears on macOS 26; earlier versions use the standard translucent materials.

## Download and install

1. [Download filo for Mac](https://github.com/Audiofool934/filo/releases/latest/download/filo-macos-universal.dmg).
2. Open the DMG and drag **filo** onto the **Applications** folder.
3. Eject the filo disk image.
4. Open filo from Applications.

filo lives in the menu bar as a small **ƒ**.
It has no Dock icon or main window; the card opens by itself the first time, and afterwards whenever you click **ƒ**.

A [ZIP alternative](https://github.com/Audiofool934/filo/releases/latest/download/filo-macos-universal.zip) contains the same app; unzip it and move **filo.app** to Applications.
GitHub's **Source code** archives are for building filo yourself.

### Verify the download (optional)

Each release lists SHA-256 checksums in `SHA256SUMS`.
Download it into the same folder as the DMG or ZIP, then run:

```sh
shasum -a 256 --ignore-missing -c SHA256SUMS
```

## First launch

Releases from 1.1.2 on are signed with a Developer ID and notarized by Apple, and both the DMG and the app carry their notarization tickets.
macOS may still ask you to confirm opening an app downloaded from the internet; that is the normal first-launch confirmation described in [Apple's guide](https://support.apple.com/en-us/102445).

If macOS says it cannot verify the developer, check that you downloaded version 1.1.2 or later from this repository's [releases](https://github.com/Audiofool934/filo/releases/latest); earlier versions were not notarized.
If a current release is blocked, or macOS says the app is damaged or will harm your computer, do not open it, and [report the exact message](https://github.com/Audiofool934/filo/issues/new/choose).

## Connect for the first time

1. Connect your USB DAC and turn on its USB DAC mode if it has one.
2. Click **ƒ**, then choose **Music** and your DAC in the bottom row of the card.
3. Turn on the switch.
4. If macOS asks whether filo may control Music, click **Allow**.
   filo only reads playback information; it does not change your library.
5. Play a lossless track in Music.

For Spotify, choose **Spotify** instead; filo applies its fixed 44.1 kHz profile.

The default **Format matching** path needs only the Automation permission from step 4.
It does not need BlackHole, a new audio driver, audio recording, or microphone access; those belong to the experimental paths in Settings.
filo also leaves your player's quality settings alone, so turn on lossless playback in the player yourself if you want it.

Continue with the [user guide](USAGE.md) to learn what the card shows.

## If something looks wrong

| What you see | Try this |
| --- | --- |
| Your DAC is not in the output list | Check the cable and the DAC's USB DAC mode, then reopen the card. |
| **Source unknown** | Play another lossless track, or disconnect and choose the track's rate manually in **••• → Settings**. |
| **Connection stopped** after sleep or unplugging | Turn the switch on again. |
| A short silence when the rate changes | This is normal; many DACs pause briefly while they switch rates. |

The [user guide's troubleshooting section](USAGE.md#troubleshooting) covers more cases.

## Update

1. In the card, choose **••• → Quit filo**.
   Quitting ends the connection and restores the output settings filo changed.
2. Install the new version as above, replacing the old app.
3. Open filo and turn the switch on again.

Your player and output choices are remembered.

## Remove

1. Choose **••• → Quit filo**, then move filo from Applications to the Trash.
2. Optionally, remove its remaining data:
   - `~/Library/Application Support/filo` holds recovery records.
     After a clean quit it contains at most an `exclusive-recovery` folder holding only a `session.lock` file.
     If `connection.json` or other `.json` files remain, a restore is still pending: open filo once more, then quit again before deleting the folder.
   - Remove saved preferences with `defaults delete blog.audiofool.filo`.
   - Remove filo from **System Settings → Privacy & Security** under Automation, and under Microphone or Screen & System Audio Recording if you tried the experimental paths.

filo installs no driver, background service, or administrator helper, so there is nothing else to remove.
