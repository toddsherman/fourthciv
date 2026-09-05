#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
APP="$(pwd)/dist/Fourth Civ.app"
bash scripts/assemble-app.sh .build/debug/FourthCivApp .build/debug/fourthciv "$APP"
echo "Built $APP"
