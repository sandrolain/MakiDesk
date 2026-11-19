#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/dist/MakiDeskNotes.app"

swift build -c "$CONFIG" --package-path "$ROOT"
BIN_DIR="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MakiDesk" "$APP/Contents/MacOS/MakiDeskNotes"
cp "$ROOT/Notes/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

CERT_NAME="MakiDesk Local Signing"
KEYCHAIN="$HOME/Library/Keychains/makidesk-signing.keychain-db"
if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$CERT_NAME"; then
  security unlock-keychain -p makidesk "$KEYCHAIN" >/dev/null 2>&1 || true
  codesign --force --deep --sign "$CERT_NAME" --keychain "$KEYCHAIN" "$APP" >/dev/null 2>&1
else
  codesign --force --sign - -r='designated => identifier "com.makidesk.app.notes"' "$APP" >/dev/null 2>&1
fi
echo "$APP"
