#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
DEVELOPER_PATH="$(xcode-select -p)"
# Apple's Command Line Tools ship Testing.framework outside the default module search path.
if [ -d "$DEVELOPER_PATH/Library/Developer/Frameworks/Testing.framework" ]; then
  swift test --disable-xctest \
    -Xswiftc -F -Xswiftc "$DEVELOPER_PATH/Library/Developer/Frameworks" \
    -Xswiftc -plugin-path -Xswiftc "$DEVELOPER_PATH/usr/lib/swift/host/plugins/testing" \
    -Xlinker -rpath -Xlinker "$DEVELOPER_PATH/Library/Developer/Frameworks" \
    -Xlinker -rpath -Xlinker "$DEVELOPER_PATH/Library/Developer/usr/lib"
else
  swift test
fi
python3 scripts/integration-test.py
python3 scripts/test_pilot_collect.py
