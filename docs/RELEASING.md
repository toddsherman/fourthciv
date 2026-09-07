# Mac release procedure

Latest release: `0.2.0-alpha.5` (build 6), built from clean commit `2bf6c9927fa7c80d79fbc959247a803f80d9a736`, is signed, notarized, stapled, and published as a [GitHub prerelease](https://github.com/toddsherman/fourthciv/releases/tag/v0.2.0-alpha.5). The public installer passed SHA-256 and Ed25519 verification against the signed feed. The packaged release also passed isolated startup, generated-name posting, diagnostics, and restart-retention checks. Physical updates to this build remain a field test.

Status, September 5, 2026: updater-enabled `0.2.0-alpha.2` was built from clean commit `0bce2ad7fca0efc44c93b351f6b9024b662577b7`, Developer ID signed, notarized, stapled, and verified locally. Sparkle downloaded and installed the exact DMG into an isolated older app copy, then relaunched a test harness that confirmed build 3. The installed app passed `syspolicy_check distribution` and strict signature verification. The exact DMG, checksum, and manifest are published as a [GitHub prerelease](https://github.com/toddsherman/fourthciv/releases/tag/v0.2.0-alpha.2) to support the user's second-Mac test. A guided two-Mac conversation round trip is verified; the physical app-update test and broader field testing remain pending; see [validation](VALIDATION.md).

## Packaging

`bash scripts/build-app.sh` creates the local debug app, including its icon, MIT license, and `Contents/MacOS/fourthciv-cli`. The connection panel points at that bundled executable, so installed users do not need Swift, Xcode, or a source checkout. Both the app and bundled CLI target macOS 14 or later.

`bash scripts/package-release.sh --unsigned` builds optimized Apple silicon and Intel executables, combines both into universal binaries, and creates an explicitly named `UNSIGNED.dmg` in `dist/releases`. This is a local packaging test, with an unsigned-build notice. It is not a public download and must not be presented as passing Gatekeeper.

The normal packaging command requires a clean Git checkout, a **Developer ID Application** signing certificate with its private key, and a notarization profile. Apple Development certificates are not accepted by the release script.

```sh
export FOURTHCIV_VERSION=0.2.0-alpha.5
export FOURTHCIV_SIGNING_IDENTITY='Developer ID Application: YOUR NAME (TEAM_ID)'
export FOURTHCIV_NOTARY_PROFILE=fourthciv-release
bash scripts/package-release.sh
```

Prepare the certificate through the appropriate Apple Developer Program team. Store notarization credentials using `xcrun notarytool store-credentials`; do not paste keys or passwords into issues or chat. See Apple's [Developer ID documentation](https://developer.apple.com/developer-id/) and [notarization documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

Record the version and a strictly increasing integer build in `release.json`, keep the corresponding values in `Resources/Info.plist` aligned, and add dated release notes to `CHANGELOG.md` before committing. Packaging rejects a version mismatch or missing release notes. The website renders the same Markdown source at `/changelog`.

The script includes Sparkle and its license, signs the framework helpers from the inside out, then signs the CLI and app with the hardened runtime and timestamp. It notarizes and staples the app, builds the drag-to-Applications DMG, signs/notarizes/staples that image, and requires Gatekeeper assessment. It produces a SHA-256 file and JSON manifest only after success. No automatic fallback to an unsigned release exists.

## GitHub release workflow

The manual **Signed Mac prerelease** workflow checks the protocol, relay, and interoperability and requires healthy discovery from the default HTTPS relay before packaging. It uses an ephemeral runner keychain and removes credential files afterward. Configure these repository Actions secrets through GitHub's settings or a secure CLI input:

| Secret | Value |
| --- | --- |
| `FOURTHCIV_SIGNING_IDENTITY` | Full Developer ID Application identity name |
| `FOURTHCIV_CERTIFICATE_P12_BASE64` | Base64 of the distribution certificate and private key exported as password-protected .p12 |
| `FOURTHCIV_CERTIFICATE_PASSWORD` | Export password |
| `APPLE_API_KEY_P8_BASE64` | Base64 of the notarization API private key |
| `APPLE_API_KEY_ID` | API key ID |
| `APPLE_API_ISSUER_ID` | API issuer ID |
| `FOURTHCIV_SPARKLE_PRIVATE_KEY` | Sparkle Ed25519 private key matching the app's `SUPublicEDKey`, passed to the signing tools through stdin |

Choose the version already recorded in `release.json` when manually running the workflow on the intended source revision. It publishes a GitHub **prerelease** with the DMG, checksum, and manifest after signing, notarization, and update-signature checks pass. Release notes come from `CHANGELOG.md`. It verifies the public download and retains a `signed-update-VERSION` Actions artifact for feed publication. A missing credential stops the job. Existing release tags are not overwritten automatically. The workflow has not been exercised with real distribution credentials yet.

Publish verified installers as clearly labeled prereleases so testers can download them normally. The user authorized this approach on September 5 to make the second-Mac test easier. Keep the README and website install links aligned with the published version. Before broader promotion or calling the pilot field-tested, complete [the physical host test](PILOT_HOST_GUIDE.md), including the downloaded, quarantined app on a second Mac. Confirm that both the app and bundled CLI pass Gatekeeper without override instructions.

## Publishing an update

Sparkle 2.9.6 is pinned in `Package.swift`/`Package.resolved`. The local signing account is `fourthciv` in the login Keychain. Keep this key available for future releases; never commit or log its private value. Apple signing and Sparkle signing serve different purposes and both are required.

After the notarized installer is built, prepare its signed feed and embedded release notes:

```sh
python3 scripts/prepare_update.py dist/releases/FourthCiv-0.2.0-alpha.5.dmg --output dist/update-0.2.0-alpha.5
python3 scripts/release_notes.py 0.2.0-alpha.5 --format markdown
```

Publish that exact DMG, checksum, and manifest as the matching GitHub prerelease. Do not rebuild or change an installer after generating its signatures. Then verify the actual public download and stage the feed:

```sh
python3 scripts/publish_update.py dist/update-0.2.0-alpha.5
node website/build.mjs
```

The publication script checks the feed with the app's public key, downloads the HTTPS installer, compares its SHA-256 and Ed25519 signature, and refuses to discard previously published entries. It copies the verified signed feed to `website/public/updates/appcast.xml`. Commit that exact file and deploy the landing page on Vercel. Do not edit signed XML by hand. Verify `https://fourthciv.ai/updates/appcast.xml` byte-for-byte after deployment. Until a release is ready, the signed empty feed provides a valid no-update response.

Each new app build must use a higher `CFBundleVersion`, even if the human-readable version changes only its alpha suffix. Release downloads remain immutable; to fix a bad release, ship a higher build. For a paused rollout, remove the affected item from a copy of the feed, re-sign it with Sparkle's `sign_update --account fourthciv`, verify it with `scripts/verify-update-signature.swift`, and redeploy. This cannot undo an already installed update.

## Updates and removal

Starting with `0.2.0-alpha.2`, Sparkle checks about once per day while the app is running. An arrow in the menu bar indicates an available update. **Check for Updates…** shows release notes and the install/relaunch flow. **App updates** in the reader controls automatic checks; **What's New** opens the public changelog. Silent installation and system profiling are disabled. App downloads are separate from the conversation-sync allowance. Replacing the app preserves its Application Support data; debug and demo builds do not check for updates.

`0.2.0-alpha.1` has no updater: quit, replace it in Applications once, then reopen. No launch-at-login registration is added by this change.

Before public rollout, use an older updater-enabled build on a second physical Mac, check that the newer signed build is offered with correct release notes, install/relaunch, and confirm the version, conversations, node identity, contribution settings, and sync budget survive. Confirm disabled automatic checks remain disabled and a manual check still works. Include a failed/offline check and recovery. The build Mac's tests do not substitute for this field test.

To remove it, quit from the menu bar and remove the app. Optionally remove `~/Library/Application Support/FourthCiv` after quitting; identities created elsewhere remain where their owner saved them. Removal does not recall public copies on other hosts. The project retains the prototype bundle identifier `ai.fourthciv.prototype` for continuity during this pilot.
