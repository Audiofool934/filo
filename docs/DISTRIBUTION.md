# Developer ID signing and notarization

Checked against Apple's documentation on 2026-09-27.
The 1.1.1 release used ad-hoc signing and was not notarized.
The 1.1.2 build 10 distribution packages have now passed Developer ID signing, Apple's notarization service, ticket stapling, and Gatekeeper assessment.
The final ZIP was extracted again to confirm its app's ticket survived packaging.
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
python3 scripts/verify-release.py --require-notarization
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
With `--require-notarization`, it also requires filo's Developer ID team, secure timestamps, Hardened Runtime, stapled tickets, and Gatekeeper acceptance for the actual packaged app and DMG.
An ad-hoc package cannot pass that release check.
It detaches its test mount on exit.
Also open the DMG in Finder to inspect the installation layout, and test a freshly downloaded signed release on a separate Mac or clean account before calling the full first-launch experience verified.
The ordinary downloaded-from-the-internet confirmation may still appear for a correctly notarized app.
Apple describes those distinct messages in [Safely open apps on your Mac](https://support.apple.com/en-us/102445).

## Publish to GitHub

The release version in `Resources/Info.plist`, the `vMAJOR.MINOR.PATCH` tag, and the release notes must agree.
Increase the bundle build number whenever the application changes.
Merge through a pull request after the required `test` check passes, then wait for CI on the merged `main` commit.
Build from that clean checkout with the signing command above; keep private keys and notarization credentials in the local Keychain.
CI builds disposable ad-hoc packages for validation, never distribution packages.

For example, to publish version 1.1.2:

```sh
git switch main
git pull --ff-only
test -z "$(git status --porcelain)"
python3 scripts/verify-release.py --require-notarization --tag v1.1.2
git tag -a v1.1.2 -m 'filo 1.1.2'
git push origin v1.1.2
gh release create v1.1.2 --verify-tag --draft --title 'filo 1.1.2' \
  --notes-file docs/releases/1.1.2.md \
  dist/filo-macos-universal.dmg dist/filo-macos-universal.zip dist/SHA256SUMS
```

Download the three assets from the draft into a temporary directory and run the same verifier against that directory.
Confirm that only the intended DMG, ZIP, and checksum file are attached, and that the notes and tag identify the tested source.
Then publish the draft:

```sh
gh release edit v1.1.2 --draft=false --latest
```

Repository release immutability locks the assets and tag after publication and supplies GitHub's release attestation.
Follow GitHub's [draft, attach, publish workflow](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases).
Corrections to binaries need a new version; never replace a published asset or move its tag.
Older releases remain available as historical records, while the README always links to the latest stable DMG.

The `Verify release` workflow downloads the public assets without credentials and checks checksums, version, signatures, notarization, and both package payloads on a fresh macOS runner.
Watch that run after publishing, then check the README's `/releases/latest/download/` links.
A failing public verification needs investigation immediately; if users are affected, mark the release as a prerelease and restore the previous stable release as latest while preparing a new patch.
The workflow can also be dispatched manually with a published tag.

## Repository safeguards

`main` requires a pull request, successful up-to-date `test` checks, resolved conversations, and linear history.
Force pushes and deletion are disabled, including for administrators.
Squash merging and automatic branch deletion keep merged changes easy to follow.
No mandatory second reviewer is configured for this single-maintainer project.

Actions use read-only tokens, full commit pins, bounded job runtimes, and cancellation of superseded CI runs.
Dependabot proposes monthly updates to Actions and hash-pinned packaging dependencies.
Dependency alerts, secret scanning, push protection, and private vulnerability reporting are enabled on GitHub.
