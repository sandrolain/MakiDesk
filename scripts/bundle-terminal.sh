#!/usr/bin/env bash
set -euo pipefail

# Builds the F0 terminal spike and wraps it in a minimal .app so it can be
# launched like the real helper (Dock icon, menus, Info.plist). SwiftPM emits a
# bare executable; this script is the bundling step the real Taskfile will
# grow into. Ad-hoc signing is enough for a local spike.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-debug}"
APP="$ROOT/dist/MakiDeskTerminal.app"

sh "$ROOT/scripts/fetch-ghosttykit.sh"
swift build --package-path "$ROOT/Terminal" -c "$CONFIG"
BIN_DIR="$(swift build --package-path "$ROOT/Terminal" -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MakiTerminal" "$APP/Contents/MacOS/MakiTerminal"
mkdir -p "$APP/Contents/Resources/bin"
cp "$BIN_DIR/makidesk" "$APP/Contents/Resources/bin/makidesk"
chmod +x "$APP/Contents/Resources/bin/makidesk"
cp "$ROOT/Terminal/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

codesign --force --sign - "$APP/Contents/Resources/bin/makidesk" >/dev/null 2>&1
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "$APP"
