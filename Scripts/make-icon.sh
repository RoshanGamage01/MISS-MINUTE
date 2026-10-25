#!/usr/bin/env bash
# Renders Miss Minute's app icon from the character renderer and writes Assets/AppIcon.icns.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build --product Minutes
BIN="$(swift build --show-bin-path)/Minutes"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

"$BIN" --export-icon "$WORK/AppIcon.iconset"
mkdir -p Assets
iconutil -c icns "$WORK/AppIcon.iconset" -o Assets/AppIcon.icns
cp "$WORK/AppIcon.iconset/icon_512x512@2x.png" Assets/AppIcon-1024.png
echo "Wrote Assets/AppIcon.icns"
