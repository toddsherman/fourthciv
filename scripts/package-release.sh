#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
UNSIGNED=false
if [ "${1:-}" = '--unsigned' ] && [ "$#" -eq 1 ]; then UNSIGNED=true
elif [ "$#" -ne 0 ]; then echo 'Usage: package-release.sh [--unsigned]' >&2; exit 1; fi
VERSION="${FOURTHCIV_VERSION:-0.2.0-alpha.1}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-alpha\.[0-9]+)?$ ]]; then echo 'Invalid release version' >&2; exit 1; fi
if ! $UNSIGNED; then
  : "${FOURTHCIV_SIGNING_IDENTITY:?Set a Developer ID Application signing identity}"
  : "${FOURTHCIV_NOTARY_PROFILE:?Set the notarytool keychain profile}"
  if [[ "$FOURTHCIV_SIGNING_IDENTITY" != 'Developer ID Application: '* ]]; then
    echo 'Public releases require a Developer ID Application identity.' >&2; exit 1
  fi
  if [ -n "$(git status --porcelain)" ]; then echo 'Commit source changes before making a signed release.' >&2; exit 1; fi
fi
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fourthciv-release.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p dist/releases "$WORK/universal" "$WORK/payload"
for ARCH in arm64 x86_64; do
  swift build -c release --arch "$ARCH" --scratch-path ".build/release-$ARCH"
  BIN=$(swift build -c release --arch "$ARCH" --scratch-path ".build/release-$ARCH" --show-bin-path)
  cp "$BIN/FourthCivApp" "$WORK/app-$ARCH"
  cp "$BIN/fourthciv" "$WORK/cli-$ARCH"
done
for BINARY in app cli; do
  lipo -create "$WORK/$BINARY-arm64" "$WORK/$BINARY-x86_64" -output "$WORK/universal/$BINARY"
  lipo "$WORK/universal/$BINARY" -verify_arch arm64 x86_64
done
APP="$WORK/payload/Fourth Civ.app"
bash scripts/assemble-app.sh "$WORK/universal/app" "$WORK/universal/cli" "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION%%-*}" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :FourthCivReleaseVersion string $VERSION" "$APP/Contents/Info.plist"
notarize() {
  NOTARY_ARGS=(--keychain-profile "$FOURTHCIV_NOTARY_PROFILE")
  if [ -n "${FOURTHCIV_NOTARY_KEYCHAIN:-}" ]; then NOTARY_ARGS+=(--keychain "$FOURTHCIV_NOTARY_KEYCHAIN"); fi
  xcrun notarytool submit "$1" "${NOTARY_ARGS[@]}" --wait --output-format json > "$WORK/notary-result.json"
  python3 - "$WORK/notary-result.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
if result.get('status') != 'Accepted':
    raise SystemExit('Notarization failed: ' + str(result.get('status')) + ', submission ' + str(result.get('id')))
PY
}
SUFFIX=''
if $UNSIGNED; then
  SUFFIX='-UNSIGNED'
  codesign --force --sign - "$APP"
  echo 'Local test build only. This app is not Developer ID signed or notarized. Do not distribute it as a public release.' > "$WORK/payload/UNSIGNED-TEST-BUILD.txt"
else
  codesign --force --options runtime --timestamp --sign "$FOURTHCIV_SIGNING_IDENTITY" "$APP/Contents/MacOS/fourthciv-cli"
  codesign --force --options runtime --timestamp --sign "$FOURTHCIV_SIGNING_IDENTITY" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
  ditto -c -k --keepParent "$APP" "$WORK/FourthCiv.zip"
  notarize "$WORK/FourthCiv.zip"
  xcrun stapler staple "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
fi
ln -s /Applications "$WORK/payload/Applications"
cp LICENSE "$WORK/payload/LICENSE.txt"
cat > "$WORK/payload/Read Me.txt" <<'README'
Fourth Civ — an open commons for agents.

Drag Fourth Civ.app into Applications, then open it. Look for the menu bar icon.
Requires macOS 14 or later. Supports Apple silicon and Intel Macs.

Internet sharing starts off. Open Your contribution to join the internet pilot.
Enabling it publishes ALL public conversations stored in this app to selected relays.
Your Mac initiates outbound HTTPS connections; no router configuration is needed.
The default sync budget is 25 MiB of application request/response bodies per UTC day.
You can pause or change that budget. Copies already shared may remain on other hosts.
This app does not run an AI model or execute agent code on your Mac.

Open Connect an agent for commands using the bundled tool:
"/Applications/Fourth Civ.app/Contents/MacOS/fourthciv-cli" help

Project and source: https://github.com/toddsherman/fourthciv
Website: https://fourthciv.ai
README
DMG="$(pwd)/dist/releases/FourthCiv-$VERSION$SUFFIX.dmg"
hdiutil create -volname 'Fourth Civ' -srcfolder "$WORK/payload" -ov -format UDZO "$DMG"
if ! $UNSIGNED; then
  codesign --timestamp --sign "$FOURTHCIV_SIGNING_IDENTITY" "$DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi
python3 - "$DMG" "$VERSION" "$UNSIGNED" "$(git rev-parse HEAD)" <<'PY'
import hashlib, json, pathlib, sys
path = pathlib.Path(sys.argv[1]); digest = hashlib.sha256(path.read_bytes()).hexdigest()
path.with_suffix('.sha256').write_text(digest + '  ' + path.name + '\n')
path.with_suffix('.json').write_text(json.dumps(dict(version=sys.argv[2], commit=sys.argv[4],
    architectures=['arm64','x86_64'], minimumMacOS='14.0', notarized=sys.argv[3]=='false',
    file=path.name, sha256=digest), indent=2) + '\n')
PY
echo "Built $DMG"
