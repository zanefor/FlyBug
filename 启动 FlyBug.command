#!/bin/bash
set -euo pipefail
FLYBUG_ROOT="$(cd "$(dirname "$0")" && pwd)"
if [[ ! -x "$FLYBUG_ROOT/FlyBug.app/Contents/MacOS/FlyBug" ]]; then
  /bin/bash "$FLYBUG_ROOT/build.sh"
fi
/usr/bin/open "$FLYBUG_ROOT/FlyBug.app"
