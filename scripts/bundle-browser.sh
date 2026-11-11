#!/usr/bin/env bash
set -euo pipefail

# Builds the browser helper and wraps it in a minimal .app. The real signing
# happens in Taskfile's `sign`, after this bundle exists.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-debug}"
APP="$ROOT/dist/MakiDeskBrowser.app"

swift build --package-path "$ROOT/Browser" -c "$CONFIG"
BIN_DIR="$(swift build --package-path "$ROOT/Browser" -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MakiDeskBrowser" "$APP/Contents/MacOS/MakiDeskBrowser"
cp "$ROOT/Browser/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

CERT_NAME="MakiDesk Local Signing"
KEYCHAIN="$HOME/Library/Keychains/makidesk-signing.keychain-db"
if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$CERT_NAME"; then
  security unlock-keychain -p makidesk "$KEYCHAIN" >/dev/null 2>&1 || true
  codesign --force --deep --sign "$CERT_NAME" --keychain "$KEYCHAIN" "$APP" >/dev/null 2>&1
else
  codesign --force --sign - "$APP" >/dev/null 2>&1
fi
echo "$APP"
