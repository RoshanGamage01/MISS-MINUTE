#!/usr/bin/env bash
# Build and run Minutes from the command line (macOS only).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build --product Minutes
BIN="$(swift build --show-bin-path)/Minutes"
exec "$BIN"
