# Mac release procedure

Status: universal DMG packaging is implemented and locally exercised. No Developer ID signed or notarized public release has been produced. Internet relay activation and physical pilot testing remain separate release gates.

## Packaging

`bash scripts/build-app.sh` creates the local debug app, including its icon, MIT license, and `Contents/MacOS/fourthciv-cli`. The connection panel points at that bundled executable, so installed users do not need Swift, Xcode, or a source checkout. Both the app and bundled CLI target macOS 14 or later.

`bash scripts/package-release.sh --unsigned` builds optimized Apple silicon and Intel executables, combines both into universal binaries, and creates an explicitly named `UNSIGNED.dmg` in `dist/releases`. This is a local packaging test, with an unsigned-build notice. It is not a public download and must not be presented as passing Gatekeeper.

The normal packaging command requires a clean Git checkout, a **Developer ID Application** signing certificate with its private key, and a notarization profile. Apple Development certificates are not accepted by the release script.

```sh
export FOURTHCIV_VERSION=0.2.0-alpha.1
export FOURTHCIV_SIGNING_IDENTITY='Developer ID Application: YOUR NAME (TEAM_ID)'
export FOURTHCIV_NOTARY_PROFILE=fourthciv-release
bash scripts/package-release.sh
```

Prepare the certificate through the appropriate Apple Developer Program team. Store notarization credentials using `xcrun notarytool store-credentials`; do not paste keys or passwords into issues or chat. See Apple's [Developer ID documentation](https://developer.apple.com/developer-id/) and [notarization documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

The script signs the CLI and app with the hardened runtime and timestamp, notarizes and staples the app, builds the drag-to-Applications DMG, signs/notarizes/staples that image, and requires Gatekeeper assessment. It produces a SHA-256 file and JSON manifest only after success. No automatic fallback to an unsigned release exists.

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

Choose the version when manually running the workflow on the intended source revision. It publishes a GitHub **prerelease** with the DMG, checksum, and manifest after signing, notarization, and assessment pass. A missing credential stops the job. Existing release tags are not overwritten automatically. The workflow has not been exercised with real distribution credentials yet.

Before enabling a landing-page download, complete [the physical host test](PILOT_HOST_GUIDE.md) and test the downloaded, quarantined app on a second Mac. Confirm that both the app and bundled CLI pass Gatekeeper without override instructions.

## Updates and removal

Pilot updates are manual: quit Fourth Civ, replace the app in Applications with the next verified release, then reopen it. The app keeps its existing local data. There is no background updater or launch-at-login registration in this release.

To remove it, quit from the menu bar and remove the app. Optionally remove `~/Library/Application Support/FourthCiv` after quitting; identities created elsewhere remain where their owner saved them. Removal does not recall public copies on other hosts. The project retains the prototype bundle identifier `ai.fourthciv.prototype` for continuity during this pilot.
