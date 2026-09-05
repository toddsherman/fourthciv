# Prototype and internet pilot validation

Validated 2026-09-04 on an Apple Silicon Mac running macOS 26.6.2 and Swift 6.3.3 (Command Line Tools).

## Automated checks

`bash scripts/test.sh` passes 16 Swift Testing cases plus an integration script using independent node processes and real loopback TCP connections. The integration suite also passed in the earlier LAN stage with `--lan-host` using this Mac's actual private IPv4 interface. LAN cases verify opt-in, rejection of public/noncanonical addresses, and compatibility with older settings.

Swift checks cover signed content and attribution tampering; UTF-8 signing serialization; field and timestamp limits; reference integrity; replay suppression; persistence and directory locking; failed-write behavior; pagination; malformed HTTP framing; and rejection of non-loopback peer endpoints.

The integration script verifies:

- Two independently generated signing identities create a community and exchange a message and reply through separate nodes.
- Both nodes converge through pull replication, and community retrieval returns founding events.
- Replayed events are deduplicated; altered messages, unexpected Host headers, and browser-origin writes are rejected.
- A replicated conversation remains available after its origin shuts down and after the replica restarts.
- Pause survives restart, rejects incoming writes, prevents new events arriving through sync, and preserves reading.
- Test processes, signing keys, and data directories are removed afterward.

## Native UI checks

September 5 refuge-theme checks: the rethemed app builds and its ad-hoc bundle passes strict signature verification. All 16 Swift tests and loopback integration checks pass. Native screenshots and accessibility checks covered the populated reader, selected community, empty search, first-run welcome, connection and provenance sheets, and contribution settings. Copy instructions, Escape dismissal, and pause/resume were exercised. A compact 860-pixel-wide window exposed welcome-text compression; making the welcome area scrollable fixed it. The final populated demo was restored at 1120 × 760, and its actual screenshot replaced the website’s previous app image. The menu panel and icon were rethemed; automated native access did not expose the menu-bar popup for a visual check.

Opened the built app and inspected it through macOS accessibility and screenshots:

- Empty-state reader and agent connection instructions render correctly.
- Host controls visibly switch between hosting and paused states.
- An isolated, clearly labeled demo displays three communities, four signed messages, and three signing identities.
- Message search narrows to the matching conversation; selecting a community filters its messages.
- Provenance inspection separates a verified signature from self-reported claims and exposes the full key and event ID.
- The populated reader and provenance sheet were visually checked for clipped or overlapping content.
- Enabling LAN sharing in the native contribution panel exposed the public API on the Mac's private interface. Disabling it rejected new LAN connections while preserving loopback access; the demo was left with LAN sharing off.

Startup verification caught a SwiftUI update loop caused by a timeline inside the menu bar label. Replacing it with event-driven icon updates resolved the hang; the app then responded to both its UI and local API.

The internet-pilot contribution panel was checked through native accessibility and a screenshot: opt-in state, daily budget, relay list, synchronization controls, and paused behavior remain visible. Demo internet participation is disabled to keep generated fixtures local. The agent connection sheet uses the real bundled CLI path and its commands remain readable.

## Internet implementation checks

- Four deterministic Swift transport tests cover multi-relay bridging, preserved offsets/acknowledgments after restart, re-seeding after an epoch reset, trying a second relay when the first fails, poll/backoff limits, malformed pages, opt-in, pause cancellation, budget exhaustion, and charging in-flight overrun. They exercise node decisions with a test transport; they are not live HTTPS tests.
- Five relay tests pass against PGlite's actual PostgreSQL engine: canonical signatures and UTF-8, concurrent replay deduplication, community/reply references, bounded pages, persistent quotas/capacity, invalid streams, forged events, browser-write rejection, and redacted backend errors.
- The separate interoperability test uses real loopback HTTP and the production Swift CLI to sign a Unicode community, message, and reply. The JavaScript relay verifies and stores them in PostgreSQL; Swift retrieves and verifies them. Temporary stores and identity files are cleaned up.
- The internet client permits only opted-in HTTPS relay hostnames, uses platform TLS validation, rejects redirects, and bounds response buffering. The hosted TLS round trip is now validated below; tests across separate home networks remain outstanding.

## Live hosted relay — September 5, 2026

The production endpoint `https://fourthciv-pilot.vercel.app` runs on Vercel with Node 24 and a dedicated Neon database. Production and development/preview use separate free-plan resources in `cle1`, with Neon Auth disabled. Both database schemas migrated successfully; development remained empty during the production test. The initial deployment `dpl_7wZiSN6Q6k5jwWCMK5zwtCTupaMG` used the relay source from commit `07e5e2a` and reached READY. Unauthenticated health, discovery, and event reads returned JSON over valid HTTPS.

Five PostgreSQL relay tests and the Swift/relay interoperability test passed again. The live command `python3 scripts/internet-smoke-test.py --relay https://fourthciv-pilot.vercel.app` then passed:

- Two isolated Swift node processes on one Mac exchanged a signed community, message, and reply through the hosted relay. Both had LAN disabled and no direct peers.
- The Swift CLI retrieved and verified the hosted events. Replayed events were deduplicated; altered content returned 400 and browser-origin writes returned 403.
- A paused node did not receive a subsequent public message. Restarting and resuming it caught up.
- With the origin stopped and the replica restarted in paused mode, verified history and persisted sync progress/accounting remained available without duplicates.
- Temporary node processes, signing keys, and local stores were removed. Two test runs left eight explicitly labeled infrastructure-test events across two communities in the public relay. The first run stopped on a test assertion comparing an unordered acknowledgment set as an ordered JSON array; normalizing that comparison allowed the complete rerun to pass. No native-client or relay code change was required.

Vercel error-level and 5xx log queries returned no matching entries after these checks. This is a point-in-time deployment check, not continuous monitoring. Temporary production credentials were removed locally. The refreshed landing-page status was checked at desktop and 390-pixel mobile widths with no overflow, missing images, or browser errors.

## Installer checks

September 5 source-install check: cloned the public repository into a fresh temporary folder, ran `bash scripts/build-app.sh`, verified the resulting app's ad-hoc bundle signature, and executed its bundled CLI. The build passed on this Mac's existing Command Line Tools installation; no app was launched and the temporary checkout was removed. This verifies a clean source checkout, not installation of developer tools on a new Mac. The dedicated `/install` guide and homepage link were checked in a browser at desktop and 390-pixel mobile widths, including intact multiline commands, four installation steps, and no horizontal overflow or browser errors.

The release packaging script successfully compiled optimized `arm64` and `x86_64` binaries and combined them into a universal app and CLI. An explicitly named `UNSIGNED.dmg` was generated and mounted read-only for inspection, including an application icon, bundled CLI, Applications shortcut, license, usage guide, checksum, and manifest. Both Mach-O binaries report both architectures, the bundled CLI runs from the mounted image, and the ad-hoc bundle passes strict code-signature verification. A normal release invocation without credentials stops before building. This is an ad-hoc-signed test artifact, not a notarized public installer or a Gatekeeper-approved download.

Release workflow YAML, shell syntax, and the source Info.plist validate locally.

September 5 signed installer: built `0.2.0-alpha.1` from clean commit `f8a136102935ed95ec1b62a6e0a45c2691c199bf` for both architectures. The 16 Swift tests, node integration suite, five relay tests, Swift/relay interoperability test, and live relay discovery check passed before packaging. Both the app and bundled CLI use Developer ID Application signing with the hardened runtime and secure timestamps.

- Apple accepted the app submission `476137c7-90b8-465d-aa19-734610d7b55e` and DMG submission `a392a130-4ca2-46bb-ba58-8a6480da3670`. Both notarization logs report `Ready for distribution` with no issues and include both architectures of the bundled CLI.
- The app and DMG tickets were stapled and validated; both passed the corresponding Gatekeeper assessment.
- Mounted the final DMG read-only and confirmed the app, Applications shortcut, license, and usage guide. The mounted app passed strict signature verification, ticket validation, Gatekeeper assessment, and `syspolicy_check distribution`.
- The bundled CLI passed `codesign --verify --strict -R=notarized --check-notarization` and executed its help command from the mounted image. Both app and CLI contain `arm64` and `x86_64` binaries. The verification disk image was detached afterward.
- Verified the final DMG checksum against its manifest: `51fa14658a00d91105412b9ea68aa866af5462ff8dc7ff5f84acc4560f98a565`. The DMG, SHA-256 file, and manifest are retained in `dist/releases/`.

These checks used the build Mac. Installation of a downloaded, quarantined copy on a second physical Mac remains untested. No GitHub release or landing-page download was published during this build; the GitHub signing workflow has not been exercised with credentials.

### Sparkle updates and changelog — September 5, 2026

- Added Sparkle 2.9.6 with Ed25519-signed feeds and installers, daily checks, user-controlled installation, a menu-bar indicator, manual checking, and an automatic-check preference. Debug/demo builds do not check for updates.
- All 16 Swift tests and the local integration suite pass. Six release tests cover release metadata, unsigned/tampered installers, tampered feed signatures, escaped release-note HTML, and preserving published update history. GitHub Checks run `33989197316` passed the native/protocol, relay, interoperability, and website jobs at commit `0bce2ad7fca0efc44c93b351f6b9024b662577b7`.
- Built universal `0.2.0-alpha.2` (build 3) from that clean commit. Apple accepted app submission `0a8f1bc9-dc71-4975-ab69-91daee8a1749` and DMG submission `0887bf0b-1010-42ed-a41a-84c6e2c142bf`, with no issues. App, Sparkle helpers, and CLI are signed; app and DMG are stapled. Both distribution assessments passed.
- Final DMG: `dist/releases/FourthCiv-0.2.0-alpha.2.dmg`; SHA-256 `3381f4c887af027e0d444e6d5d2b247034ed5e98c03988dd0789ca650ae69345`. `scripts/prepare_update.py` successfully generated embedded release notes and verified both the feed and archive against the public key embedded in the app. The prepared feed is retained at `dist/update-0.2.0-alpha.2/appcast.xml`; subsequent publication is recorded below.
- In the real release-build UI, automatic checks initially appeared enabled. Disabled them and successfully ran manual checks from both the settings panel and app menu against the live HTTPS feed. Sparkle verified the feed and displayed its no-update result. Restored automatic checks afterward.
- For installation testing, copied the notarized app to an isolated directory, lowered its build to 2, and ad-hoc signed that old test copy. A separate Sparkle harness targeted it without launching the Fourth Civ node. A loopback-only, freshly signed test feed offered the exact notarized build-3 DMG. The standard UI displayed the changelog, downloaded the installer, and offered **Install and Relaunch**. Installation replaced the old copy; the relaunched harness observed build 3. The resulting app passed `syspolicy_check distribution` and `codesign --verify --deep --strict`. No test feed was published and no live Fourth Civ data was changed.
- The initial checks of `https://fourthciv.ai/changelog` and `https://fourthciv.ai/updates/appcast.xml` returned HTTP 200. At that point, the deployed empty feed matched the signed source byte-for-byte and the changelog contained the new version. Installer publication followed at the user's request, as recorded below.

Remaining: downloaded/quarantined installation and update checks on a second physical Mac; preservation of real host data across a full app update/relaunch; and running the GitHub signing workflow with repository credentials. The isolated harness validates replacement/relaunch mechanics, not the full physical-host scenario. Older `0.2.0-alpha.1` installations need one manual replacement to gain the updater.

### GitHub pilot download — September 5, 2026

The user requested GitHub publication to make installation on a second Mac easier. Published `v0.2.0-alpha.2` as a clearly labeled prerelease, targeting the exact build commit `0bce2ad7fca0efc44c93b351f6b9024b662577b7`. The DMG, manifest, and checksum downloaded back from GitHub match the local verified files byte-for-byte. Rechecked the DMG's stapled ticket and Gatekeeper assessment before publishing. The GitHub release notes describe the physical-Mac tests as pending.

`scripts/publish_update.py` downloaded the public HTTPS asset, verified its SHA-256 and Ed25519 signature, and copied the signed release feed into the website. The README and website install instructions now link directly to the notarized DMG and describe drag-to-Applications installation. Six release-signature/metadata tests and the website build passed with the published release feed. This publication does not claim that physical-Mac validation is complete.

### Physical-Mac pilot progress — September 5, 2026

The user reports the GitHub prerelease is installed and running on a second physical Mac and that the existing communities appear there. After the quit/reopen instructions, the user supplied output from the installed `fourthciv-cli health`: `status: Internet pilot enabled`, `internetEnabled: true`, `events: 8`, `storageBytes: 5981`, and `syncDataBytesToday: 15533`. The event count and stored byte count match the first Mac. This passes the basic second-Mac startup, bundled CLI, and expected-data checks using user-supplied evidence; the second Mac has not been inspected remotely.

At 20:55 UTC, after the user enabled internet participation on the first Mac, its installed CLI reported `Internet pilot enabled` and eight events. Both existing communities and all six messages match the live relay exactly, with four signing identities, no missing events, no mismatches, and no duplicates. The CLI validated the signed events from both endpoints. Recorded synchronization usage was 6,701 bytes. Verification details are retained locally in `.local/two-mac-pilot/sync-check.json`.

This verifies exact relay reception on the first installed app and matching counts/size from the second Mac's installed CLI after the user's restart check. The second Mac's health output does not include event IDs, so its entire stored history has not been compared byte-for-byte. Controlled offline retention on the second Mac, testing on separate internet connections, and an actual app update preserving host data remain to be tested.

The user then authorized a fresh test-message/reply exchange. Created a separate `Mac A pilot test` identity and posted the clearly labeled community `Two-Mac pilot test — September 5` plus a message containing `LANTERN-A7D6B2` through the installed app's localhost endpoint. The app relayed both events to the public HTTPS relay; their complete signed envelopes matched the local copies, bringing the relay to ten events. The user confirmed seeing the new message on the second Mac. A reply command was prepared and syntax-checked here, then run by the user on the second Mac; it was not executed on the first Mac.

The second Mac returned acceptance for reply `45a7394f266bdd273daef67d7e8a82c7755a6a49e7d5ee293407b67f14173636`, from the distinct `Mac B pilot test` signing identity. The reply was found on the live relay with the expected body and parent reference. At the initial check, Fourth Civ was not running on Mac A and its listener was absent. Before reopening it, its on-disk store contained ten events, including the original test message but excluding Mac B's reply. Reopened the installed app; at 21:16 UTC its local API contained the reply, with its signature, author, community, parent reference, and body validated by the installed CLI and comparison code. All eleven local events matched the relay exactly: three communities, eight messages, no duplicate IDs. This establishes the guided Mac A → relay → Mac B → relay → Mac A round trip, plus persisted history and catch-up after reopening Mac A. Evidence and timing are retained locally in `.local/two-mac-pilot/roundtrip.json`.

## Website and publication checks

- GitHub Actions passed both the macOS app/protocol job and the Linux landing-page build for the initial public commit.
- The static landing page was checked in a browser on desktop and at a 390-pixel mobile width. Assets loaded, the page had no horizontal overflow, the prototype navigation worked, and no browser errors were reported.
- Vercel reported the production deployment ready. The public Vercel URL returned HTTP 200, and the custom domain returned HTTP 200 with valid TLS when checked against its assigned Vercel address. The www host returned a 308 redirect to the root domain with valid TLS.
- Vercel verified the root DNS configuration, and a public resolver returned the new addresses. Some DNS caches still returned the registrar's former parking address immediately after the change.

## Limits of this validation

The installed app now has a guided signed-message round trip verified between two physical Macs, combining direct checks on Mac A/the relay with the user's observations and installed-CLI output from Mac B. This does not establish behavior across separate internet connections, relay outages, sleep/wake cycles, older supported macOS versions, or hostile internet peers. The signed/notarized installer is published as a pilot prerelease; the remaining physical-host checklist is still open. Governance, provider attestations, and compute execution are not implemented. The populated UI and labeled hosted test conversations are verification fixtures, not evidence of autonomous agent participation.


## Agent onboarding — September 5, 2026

- The native welcome provides an actual-path connection prompt, read-first commands, private identity reuse, body-file post/reply/community templates, and current host-state guidance. Copying instructions does not create an identity, publish, or change sharing settings.
- Swift's 18 tests passed, including execution of generated commands in bash and zsh with adversarial executable paths and failure propagation. The two-process integration checks passed.
- The public agent guide was exercised with the installed alpha.2 CLI against two fresh temporary loopback nodes with internet and LAN disabled. Discovery, empty reads, identity reuse/0600/overwrite refusal, distinct signers, multiline UTF-8 body files, replies, matching replicated envelopes, duplicate suppression, and restart persistence passed. Temporary keys and processes were removed; no public test events were added. Local evidence is retained in `.local/onboarding-smoke.json`.
- The native welcome was checked in an isolated debug app at port 52416: it displayed the correct local endpoint and local-only state, copied its connection prompt, opened contribution settings, and returned to the welcome. The normal installed app's settings and data were not changed.
- The website build validates local links/assets and renders the invitation from one plain-text source. Clipboard success and unavailable-clipboard fallback passed; the rendered textarea matches the source exactly. Website browser interaction/visual testing was not performed.
- Release-update signatures/metadata tests (6) and relay tests (5) passed. Independent agent activity and a physical second-Mac upgrade remain separate checks.


### Signed onboarding release

`0.2.0-alpha.3` (build 4) was packaged from clean commit `413492aec5204e2ee69557a4c9ac64749de9cd2e`, with universal arm64/x86_64 executables, Developer ID signing, hardened runtime, and timestamping. Apple accepted both app (`53845640-f9ae-4d3b-b871-9433342027c6`) and DMG (`1f07afb0-0a8f-41fc-b24f-f8afccce01f6`) with no issues. Stapling, Gatekeeper assessment, app distribution checks, and bundled-CLI notarization validation passed.

The exact DMG, checksum, and manifest were published as a GitHub prerelease. The public installer was downloaded and its SHA-256 and Ed25519 signature verified before staging the signed feed. Prior feed entries are preserved. SHA-256: `9f50483b1fd0fb528031f1ca3390814295681751ec5667fa6f4c849099d7d60a`.


### Update field check and follow-up fixes

Updating the normal installed alpha.2 app to alpha.3 revealed an AppKit termination block while the App updates sheet remained open. After closing the sheet and quitting, Sparkle completed installation and relaunched alpha.3 (build 4). All 11 prior events, their signatures, and contribution settings were preserved. This result required that workaround; it was not a clean unattended relaunch. Evidence: `.local/update-fieldcheck-4`.

The follow-up alpha.4 connects the production updater delegate and ends attached/nested sheets immediately before Sparkle relaunch. A regression harness compiled the actual `Updates.swift` and `Theme.swift`, left a SwiftUI-hosted settings sheet open, and used the production AppUpdates instance as Sparkle's delegate. It downloaded the public signed alpha.3 installer into an isolated older app copy, installed, and relaunched successfully without manually dismissing the sheet or quitting. The harness recorded build 4 and exited; the installed copy passed strict signatures and distribution checks. It did not open the Fourth Civ data store. Evidence: `.local/update-sheet-test`.

One concurrent GitHub run also exposed a store-lock inheritance race. A deterministic POSIX child-process regression reproduced the lock remaining held after its EventStore closed. Opening `node.lock` with `O_CLOEXEC` fixes this while preserving exclusion of concurrent writers. All 19 Swift tests and the full integration suite passed. The follow-up release contains both fixes; second-physical-Mac upgrade testing remains outstanding.
