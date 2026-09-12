#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Run after swift build/test has built FourthCivCore and the pinned Sparkle framework.
swiftc -parse-as-library -D DEBUG \
  scripts/menu-icon-test.swift Sources/FourthCivApp/MenuBarIcon.swift \
  Sources/FourthCivApp/Updates.swift Sources/FourthCivApp/Theme.swift \
  -I .build/debug/Modules .build/debug/FourthCivCore.build/*.o \
  -F .build/debug -framework Sparkle -framework AppKit -framework SwiftUI \
  -Xlinker -rpath -Xlinker "$PWD/.build/debug" \
  -o .build/menu-icon-test
.build/menu-icon-test
