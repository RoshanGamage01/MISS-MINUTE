#!/usr/bin/env bash
# Build Minutes as a macOS .app (and optional .dmg).
# Run on macOS with Xcode / Command Line Tools installed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Minutes"
BUNDLE_ID="com.minutes.app"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
CONFIG="${CONFIG:-release}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"   # e.g. "Developer ID Application: Your Name (TEAMID)"
MAKE_DMG="${MAKE_DMG:-0}"
DIST_DIR="${DIST_DIR:-"$ROOT/dist"}"

if ! command -v swift >/dev/null 2>&1; then
  echo "error: swift not found. Install Xcode or Command Line Tools on a Mac." >&2
  exit 1
fi

echo "==> swift build -c $CONFIG --product $APP_NAME"
swift build -c "$CONFIG" --product "$APP_NAME"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
  echo "error: built binary not found at $BIN_PATH" >&2
  exit 1
fi

APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

echo "==> packaging $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

# Copy SwiftPM resource bundles if present.
shopt -s nullglob
for bundle in "$(dirname "$BIN_PATH")"/*.bundle; do
  cp -R "$bundle" "$RESOURCES_DIR/"
done
shopt -u nullglob

# Prefer the checked-in Info.plist, then rewrite version keys.
if [[ -f "$ROOT/Sources/Minutes/Info.plist" ]]; then
  cp "$ROOT/Sources/Minutes/Info.plist" "$CONTENTS/Info.plist"
else
  cat > "$CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
EOF
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$CONTENTS/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_NUMBER" "$CONTENTS/Info.plist"

ENTITLEMENTS="$ROOT/Sources/Minutes/Minutes.entitlements"
if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "==> codesign with identity: $SIGN_IDENTITY"
  if [[ -f "$ENTITLEMENTS" ]]; then
    codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
  else
    codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
  fi
  codesign --verify --verbose=2 "$APP_BUNDLE"
else
  echo "==> ad-hoc sign (unsigned distribution: Gatekeeper may block)"
  codesign --force --deep --sign - "$APP_BUNDLE" || true
fi

if [[ "$MAKE_DMG" == "1" ]]; then
  DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"
  echo "==> creating $DMG_PATH"
  rm -f "$DMG_PATH"
  hdiutil create -volname "$APP_NAME" -srcfolder "$APP_BUNDLE" -ov -format UDZO "$DMG_PATH"
  echo "DMG: $DMG_PATH"
fi

echo "App: $APP_BUNDLE"
echo "Open with: open \"$APP_BUNDLE\""
