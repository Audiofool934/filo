# USB DAC mode evidence correction

Recorded on 2026-09-26 Asia/Singapore, corresponding to 2026-09-25 UTC.
During the Spotify tap-autostart investigation, the operator reported that the WALKMAN's USB DAC mode had not been enabled and had now been turned on.
The affected earlier time interval has not been established.
Earlier descriptions of the device as being in USB DAC mode must therefore be read as an unverified setup assumption, not an independently observed receiver state.
This correction does not assert that every earlier run occurred with the mode off.

## What remains measured

The saved host-side callback bytes, rejected process-tap samples, comparison results, format readbacks, and cleanup observations retain their stated software measurement boundaries.
Enumerating WALKMAN in Core Audio and successfully invoking its output callback do not independently establish the state of Sony's Music player USB DAC screen.
Neither a passing callback comparison nor a matching nominal sample rate is a receiver-side sample comparison.
Historical raw receipts and their hashes are retained unchanged; this note corrects their environmental interpretation.
In particular, the `output` description in the historical [AudioQueue evidence index](../validation/audioqueue-first-start/index.json) contains the earlier assumption.

Sony's [USB DAC setup instructions](https://helpguide.sony.net/dmp/1302/v1/en/contents/TP1000729844.html), checked again on the correction date, describe selecting USB DAC in the USB connection menu and then activating USB DAC in Music player and accepting its start prompt.
The reviewed instructions do not specify when host audio enumeration begins relative to those steps.
Sony's [USB DAC screen documentation](https://helpguide.sony.net/dmp/1302/v1/en/contents/TP1000731800.html) describes signal presence and format information, not a PCM checksum or sample readback.

## Separately identified repeat

After the operator's confirmation, the [Spotify tap-autostart repeat](spotify-tap-autostart-observation.md) used a fresh Spotify process and a timestamped capture of the same canonical reference.
Its mode evidence is the operator's confirmation, not an independently captured Sony display or receiver report.
It retained the same changed 512-frame onset at the process tap and failed exact integer representation before those changed samples could be published to the output callback.
Thus the experimental tap-start setting was insufficient in that condition, while the responsible component and receiver samples remain unknown.
