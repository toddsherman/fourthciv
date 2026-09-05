#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then echo 'Usage: assemble-app.sh GUI_BINARY CLI_BINARY APP_PATH [SPARKLE_FRAMEWORK]' >&2; exit 1; fi
GUI_BINARY="$1"; CLI_BINARY="$2"; APP_PATH="$3"
SPARKLE_FRAMEWORK="${4:-$(dirname "$GUI_BINARY")/Sparkle.framework}"
if [ ! -d "$SPARKLE_FRAMEWORK" ]; then echo 'Missing Sparkle.framework; build the app with Swift Package Manager first.' >&2; exit 1; fi
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$GUI_BINARY" "$APP_PATH/Contents/MacOS/FourthCiv"
cp "$CLI_BINARY" "$APP_PATH/Contents/MacOS/fourthciv-cli"
cp Resources/Info.plist "$APP_PATH/Contents/Info.plist"
python3 - "$APP_PATH/Contents/Info.plist" <<'PY'
import json, plistlib, sys
release = json.load(open('release.json'))
with open(sys.argv[1], 'rb') as f: info = plistlib.load(f)
info.update(CFBundleVersion=str(release['build']), CFBundleShortVersionString=release['version'].split('-')[0], FourthCivReleaseVersion=release['version'])
with open(sys.argv[1], 'wb') as f: plistlib.dump(info, f)
PY
mkdir -p "$APP_PATH/Contents/Frameworks"
python3 - "$APP_PATH/Contents/Frameworks/Sparkle.framework" <<'PY'
import pathlib, shutil, sys
framework = pathlib.Path(sys.argv[1])
if framework.exists(): shutil.rmtree(framework)
PY
ditto "$SPARKLE_FRAMEWORK" "$APP_PATH/Contents/Frameworks/Sparkle.framework"
cp Resources/Sparkle-LICENSE.txt "$APP_PATH/Contents/Resources/Sparkle-LICENSE.txt"
cp LICENSE "$APP_PATH/Contents/Resources/LICENSE"
if [ ! -f dist/FourthCiv.icns ] || [ scripts/make-icon.swift -nt dist/FourthCiv.icns ]; then
  mkdir -p dist
  swift scripts/make-icon.swift dist/FourthCiv.iconset
  iconutil -c icns dist/FourthCiv.iconset -o dist/FourthCiv.icns
fi
cp dist/FourthCiv.icns "$APP_PATH/Contents/Resources/FourthCiv.icns"
codesign --force --sign - "$APP_PATH/Contents/MacOS/fourthciv-cli"
codesign --force --sign - "$APP_PATH"
