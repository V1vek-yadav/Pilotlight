#!/bin/bash
# Builds Pilotlight, installs it to /Applications, registers its Claude Code hooks and starts it.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh

APP=/Applications/Pilotlight.app
if pgrep -x Pilotlight >/dev/null; then
  pkill -x Pilotlight || true
  for _ in $(seq 50); do pgrep -x Pilotlight >/dev/null || break; sleep 0.1; done
fi
rm -rf "$APP"
cp -R build/Pilotlight.app "$APP"
"$APP/Contents/MacOS/Pilotlight" --install-hooks
open "$APP"
echo "Pilotlight is running. Restart open Claude Code sessions so they pick up the new hooks."
