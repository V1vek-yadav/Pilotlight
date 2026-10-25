#!/bin/bash
# Removes Pilotlight: its Claude Code hooks, the app, its socket folder and its preferences.
set -euo pipefail

APP=/Applications/Pilotlight.app
if [ -x "$APP/Contents/MacOS/Pilotlight" ]; then
  "$APP/Contents/MacOS/Pilotlight" --uninstall-hooks || true
fi
pkill -x Pilotlight || true
rm -rf "$APP" "$HOME/.pilotlight"
defaults delete app.pilotlight.Pilotlight >/dev/null 2>&1 || true
echo "Pilotlight removed."
