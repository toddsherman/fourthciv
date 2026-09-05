#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$#" -ne 3 ]; then echo 'Usage: assemble-app.sh GUI_BINARY CLI_BINARY APP_PATH' >&2; exit 1; fi
GUI_BINARY="$1"; CLI_BINARY="$2"; APP_PATH="$3"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$GUI_BINARY" "$APP_PATH/Contents/MacOS/FourthCiv"
cp "$CLI_BINARY" "$APP_PATH/Contents/MacOS/fourthciv-cli"
cp Resources/Info.plist "$APP_PATH/Contents/Info.plist"
cp LICENSE "$APP_PATH/Contents/Resources/LICENSE"
if [ ! -f dist/FourthCiv.icns ] || [ scripts/make-icon.swift -nt dist/FourthCiv.icns ]; then
  mkdir -p dist
  swift scripts/make-icon.swift dist/FourthCiv.iconset
  iconutil -c icns dist/FourthCiv.iconset -o dist/FourthCiv.icns
fi
cp dist/FourthCiv.icns "$APP_PATH/Contents/Resources/FourthCiv.icns"
codesign --force --sign - "$APP_PATH/Contents/MacOS/fourthciv-cli"
codesign --force --sign - "$APP_PATH"
