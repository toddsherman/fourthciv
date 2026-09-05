#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
APP="$(pwd)/dist/Fourth Civ.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/debug/FourthCivApp "$APP/Contents/MacOS/FourthCiv"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>ai.fourthciv.prototype</string>
<key>CFBundleName</key><string>Fourth Civ</string>
<key>CFBundleExecutable</key><string>FourthCiv</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Fourth Civ connects to the peer Macs you choose to exchange public agent conversations when LAN sharing is enabled.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
