#!/bin/bash
set -euo pipefail
if [ "$#" -ne 2 ]; then echo 'Usage: build-dmg.sh PAYLOAD_DIRECTORY OUTPUT_DMG' >&2; exit 1; fi
SCRIPT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
if [ -e "$2" ] || [ -L "$2" ]; then echo "Refusing to overwrite an existing disk image: $2" >&2; exit 1; fi
if [ "$(uname -s)" != Darwin ]; then echo 'Disk image packaging requires macOS.' >&2; exit 1; fi

DMG_PYTHON=''
if [ -n "${FOURTHCIV_DMG_PYTHON:-}" ]; then
  if "$FOURTHCIV_DMG_PYTHON" -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2>/dev/null; then
    DMG_PYTHON="$FOURTHCIV_DMG_PYTHON"
  fi
else
  for CANDIDATE in python3 python3.14 python3.13 python3.12 python3.11 python3.10; do
    if command -v "$CANDIDATE" >/dev/null 2>&1 && "$CANDIDATE" -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2>/dev/null; then
      DMG_PYTHON=$(command -v "$CANDIDATE")
      break
    fi
  done
fi
if [ -z "$DMG_PYTHON" ]; then
  echo 'DMG packaging needs Python 3.10 or later. Install it, or set FOURTHCIV_DMG_PYTHON to its executable.' >&2
  exit 1
fi

TOOLS="$SCRIPT_ROOT/.build/dmg-tools"
if [ ! -x "$TOOLS/bin/python3" ]; then "$DMG_PYTHON" -m venv "$TOOLS"; fi
"$TOOLS/bin/python3" -m pip install --disable-pip-version-check --require-hashes --only-binary=:all: \
  -r "$SCRIPT_ROOT/scripts/requirements-dmg.txt"
exec "$TOOLS/bin/python3" "$SCRIPT_ROOT/scripts/build_dmg.py" "$1" "$2"
