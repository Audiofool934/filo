# Developer ID signing and notarization

Checked against Apple's documentation on 2026-09-27.
The current public 1.1.1 download is ad-hoc signed and not notarized.
Adding a DMG does not change that status.
Only describe a release as notarized after Apple accepts it and the verification steps below pass.

## One-time account setup

1. Join the [Apple Developer Program](https://developer.apple.com/programs/enroll/) using your Apple Account with two-factor authentication.
   Membership currently costs 99 USD per year, or the local price shown during enrollment.
   Complete identity verification, agreements, and payment yourself.
2. As the Account Holder, create a **Developer ID Application** certificate in [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/certificates/list).
   Follow Apple's [certificate instructions](https://developer.apple.com/help/account/certificates/create-developer-id-certificates) to create a certificate signing request on this Mac, upload the request, and install the downloaded certificate.
   Keep its matching private key in your Keychain.
   Apple Development is a development certificate; Developer ID Installer is for a `.pkg` installer, which filo does not use.
3. Confirm that the certificate and private key form a valid identity:

   ```sh
   security find-identity -v -p codesigning
   ```

   The result must contain `Developer ID Application: YOUR NAME (TEAMID)`.
   Do not export or commit the private key just to run the local release process.
4. Create an [app-specific password](https://support.apple.com/en-us/102654) for notarization in your Apple Account.
   Enter it only in the local secure prompt below, not in chat, source files, command arguments, or GitHub issue text.

   ```sh
   xcrun notarytool store-credentials "filo-notary" \
     --apple-id "YOUR_APPLE_ACCOUNT_EMAIL" \
     --team-id "YOUR_TEAM_ID"
   ```

   `notarytool` prompts for the password and validates the credentials before storing them in Keychain.
   An App Store Connect API key is also supported by Apple, but is not required for this local workflow.

## Make the release

Use Xcode 26 or Command Line Tools with the macOS 26 SDK, Python 3.10+, and the certificate's full name from `find-identity`.
The account setup and initial certificate creation are separate from this build command.

```sh
SIGNING_IDENTITY="Developer ID Application: YOUR NAME (TEAMID)" \
  bash scripts/package-release.sh --notarize filo-notary
python3 scripts/verify-release.py
```

The script builds both CPU architectures in isolation, signs the nested laboratory executable before the app, and enables Hardened Runtime with secure timestamps.
It submits an app ZIP to Apple, requires `Accepted`, and staples the ticket to the app.
It then creates and signs the DMG, submits that image, staples its ticket, and checks both with Gatekeeper.
The final ZIP is created from the already-stapled app, so both distribution formats include the app's offline ticket.
Two submissions are used here because filo distributes both an independently usable ZIP and a signed DMG.
Apple's [notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow) explains containers, credentials, submission status, and stapling.

Final artifacts are `dist/filo-macos-universal.dmg`, `dist/filo-macos-universal.zip`, and `dist/SHA256SUMS`.
Submission receipts are kept locally under `dist/notarization/`.
The script does not upload release assets to GitHub.
Publish the DMG as the main download and keep the ZIP as an alternative only after verification succeeds.

If Apple rejects a submission, use the receipt's submission ID to retrieve the reason:

```sh
xcrun notarytool log SUBMISSION_ID --keychain-profile filo-notary submission-log.json
```

Fix the reported issue, rebuild, and resubmit.
Do not weaken Hardened Runtime or remove protections to make an unrelated rejection disappear.
Notarization is an automated security check for distribution outside the Mac App Store; it does not put filo on the App Store or constitute App Review.
See Apple's [Developer ID overview](https://developer.apple.com/developer-id/).

## Local and CI packages

```sh
bash scripts/package-release.sh
python3 scripts/verify-release.py
```

Without `--notarize`, the script does not contact Apple's notary service or use stored notarization credentials.
With no `SIGNING_IDENTITY`, the app is ad-hoc signed and the DMG is unsigned.
These artifacts are useful for layout and payload checks, but they still have the first-launch limitations described in the installation guide.
CI uses this path and cannot establish Developer ID or notarization success.
The hash-pinned Python tools only create the disk image and Finder layout; they are not bundled into filo.

## Final checks

The verification script checks SHA-256 sums, mounts only its own image, verifies the Applications shortcut, checks signatures and both architectures, and compares all app file contents between DMG and ZIP.
It detaches its test mount on exit.
Also open the DMG in Finder to inspect the installation layout, and test a freshly downloaded signed release on a separate Mac or clean account before calling the full first-launch experience verified.
The ordinary downloaded-from-the-internet confirmation may still appear for a correctly notarized app.
Apple describes those distinct messages in [Safely open apps on your Mac](https://support.apple.com/en-us/102445).
