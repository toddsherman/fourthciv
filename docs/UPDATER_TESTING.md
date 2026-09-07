# Native popup update regression

Use a real SwiftUI `.sheet`, including a sheet presented from another sheet. Hosting SwiftUI content inside a manually constructed `NSWindow` does not exercise SwiftUI's presentation bindings and missed the nested-popup shutdown failure.

`scripts/prepare_popup_update_test.py` compiles the production `Updates.swift`, `Theme.swift`, and dismissal modifier into a separate test application. Sparkle updates an isolated copy of a published Fourth Civ app; the test application never opens a Fourth Civ node, conversation store, or signing identity.

## Prepare and run

Run `swift build` first. Supply a copy of the currently published app and a new output directory:

```bash
python3 scripts/prepare_popup_update_test.py \
  '/path/to/Fourth Civ.app' \
  --output .local/popup-regression-normal
```

The source app is only read. The script lowers the copied host's build number and ad-hoc signs that test copy. It does not change the public feed or disable signature validation. The feed must offer the source build or a newer version.

1. Open the generated **Popup Update Test.app**, not `installed/Fourth Civ.app`.
2. Choose **Open SwiftUI popup**, then **Open nested popup**.
3. Choose **Check for Updates**, then **Install Update**. If the popup obscures progress, choose **Check for Updates** again to bring the updater forward.
4. Choose **Install and Relaunch** while both popups remain open. Do not dismiss them manually.
5. Verify the original test process exited, `installed/Fourth Civ.app/Contents/Info.plist` has the new build, and `launched-build.txt` records that same build. The relaunched test application writes that result and exits automatically.
6. Verify the installed copy with `codesign --verify --deep --strict`.

Repeat with a fresh output directory and **Simulate resumed installation** enabled before checking. This omits Sparkle's optional postponement callback while forwarding its relaunch callback to the production delegate, exercising the documented resumed-install path.

For the Save dialog check, choose **Check for Updates**, dismiss the offer with **Remind Me Later**, then choose **Test Save dialog dismissal**. The production cleanup must cancel the real modal save panel, return `.cancel`, and write `save-panel.txt` containing `dismissed`. This is a focused cleanup check, not an installer run with the Save panel open; no report is saved.

Keep every app sheet opted into `dismissForAppUpdate()`. Ending its native window alone does not reset SwiftUI's presentation state and can cause a nested sheet to reappear while Sparkle is quitting the process.

## Scope

This tests actual download, replacement, and relaunch against the signed public installer, plus SwiftUI dismissal and modal-loop cleanup. It does not replace a full installed-app update on a second physical Mac or validate preservation of that Mac's real data. Close popups before upgrading an older app to the first release containing this fix: the old process still runs its previous shutdown code.
