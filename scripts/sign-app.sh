#!/bin/bash
set -euo pipefail
if [ "$#" -ne 2 ]; then echo 'Usage: sign-app.sh APP SIGNING_IDENTITY' >&2; exit 1; fi
APP="$1"; SIGNING_IDENTITY="$2"
if [[ "$SIGNING_IDENTITY" != 'Developer ID Application: '* ]]; then echo 'A Developer ID Application identity is required.' >&2; exit 1; fi
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
# Sign nested code from the inside out, preserving Sparkle's helper entitlements.
for COMPONENT in "$SPARKLE/Autoupdate" "$SPARKLE/Updater.app" "$SPARKLE/XPCServices/Downloader.xpc" "$SPARKLE/XPCServices/Installer.xpc" "$APP/Contents/Frameworks/Sparkle.framework" "$APP/Contents/MacOS/fourthciv-cli" "$APP"; do
  codesign --force --options runtime --timestamp --preserve-metadata=entitlements --sign "$SIGNING_IDENTITY" "$COMPONENT"
done
codesign --verify --deep --strict --verbose=2 "$APP"
