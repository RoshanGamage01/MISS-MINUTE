#!/usr/bin/env bash
# Build a debug .app bundle and launch it.
# UserNotifications / SMAppService require a real bundle — a bare swift binary will crash.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG=debug DIST_DIR="$ROOT/.build/dev" MAKE_DMG=0 ./Scripts/build-app.sh
APP="$ROOT/.build/dev/Minutes.app"
BIN="$APP/Contents/MacOS/Minutes"
if [[ ! -x "$BIN" ]]; then
  echo "error: expected bundled binary at $BIN" >&2
  exit 1
fi

echo "==> launching $APP"
# Run the executable inside the bundle so Bundle.main points at the .app
# (keeps console logs in this terminal).
exec "$BIN"
