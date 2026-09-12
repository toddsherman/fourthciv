#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
UNSIGNED=false
if [ "${1:-}" = '--unsigned' ] && [ "$#" -eq 1 ]; then UNSIGNED=true
elif [ "$#" -ne 0 ]; then echo 'Usage: package-release.sh [--unsigned]' >&2; exit 1; fi
CONFIG_VERSION=$(python3 -c 'import json; print(json.load(open("release.json"))["version"])')
VERSION="${FOURTHCIV_VERSION:-$CONFIG_VERSION}"
if [ "$VERSION" != "$CONFIG_VERSION" ]; then echo 'Release version must match release.json; update release.json and CHANGELOG.md together.' >&2; exit 1; fi
BUILD_NUMBER=$(python3 -c 'import json; print(json.load(open("release.json"))["build"])')
if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then echo 'Release build must be a positive, increasing integer.' >&2; exit 1; fi
python3 scripts/release_notes.py "$VERSION" >/dev/null
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-alpha\.[0-9]+)?$ ]]; then echo 'Invalid release version' >&2; exit 1; fi
SUFFIX=''
if $UNSIGNED; then SUFFIX='-UNSIGNED'; fi
DMG="$(pwd)/dist/releases/FourthCiv-$VERSION$SUFFIX.dmg"
if [ -e "$DMG" ] || [ -L "$DMG" ]; then
  echo "Refusing to overwrite an existing release installer: $DMG" >&2; exit 1
fi
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
bash scripts/assemble-app.sh "$WORK/universal/app" "$WORK/universal/cli" "$APP" "$BIN/Sparkle.framework"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION%%-*}" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :FourthCivReleaseVersion $VERSION" "$APP/Contents/Info.plist"
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
  SUBMISSION_ID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$WORK/notary-result.json")
  xcrun notarytool log "$SUBMISSION_ID" "${NOTARY_ARGS[@]}" "$WORK/notary-log.json"
  python3 - "$WORK/notary-log.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
if result.get('issues'):
    raise SystemExit('Review notarization issues before distribution: ' + str(result['issues']))
PY
}
if $UNSIGNED; then
  codesign --force --sign - "$APP"
  echo 'Local test build only. This app is not Developer ID signed or notarized. Do not distribute it as a public release.' > "$WORK/payload/UNSIGNED-TEST-BUILD.txt"
else
  bash scripts/sign-app.sh "$APP" "$FOURTHCIV_SIGNING_IDENTITY"
  ditto -c -k --keepParent "$APP" "$WORK/FourthCiv.zip"
  notarize "$WORK/FourthCiv.zip"
  xcrun stapler staple "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
  syspolicy_check distribution "$APP"
  codesign --verify --strict -R=notarized --check-notarization "$APP/Contents/MacOS/fourthciv-cli"
fi
bash scripts/build-dmg.sh "$WORK/payload" "$DMG"
if ! $UNSIGNED; then
  codesign --timestamp --sign "$FOURTHCIV_SIGNING_IDENTITY" "$DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi
python3 - "$DMG" "$VERSION" "$UNSIGNED" "$(git rev-parse HEAD)" "$BUILD_NUMBER" <<'PY'
import hashlib, json, pathlib, sys
path = pathlib.Path(sys.argv[1]); digest = hashlib.sha256(path.read_bytes()).hexdigest()
path.with_suffix('.sha256').write_text(digest + '  ' + path.name + '\n')
path.with_suffix('.json').write_text(json.dumps(dict(version=sys.argv[2], build=int(sys.argv[5]), commit=sys.argv[4],
    architectures=['arm64','x86_64'], minimumMacOS='14.0', notarized=sys.argv[3]=='false',
    file=path.name, sha256=digest), indent=2) + '\n')
PY
echo "Built $DMG"
