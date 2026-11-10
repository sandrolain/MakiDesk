#!/usr/bin/env bash
set -euo pipefail

# Builds the Docker helper and wraps it in a minimal .app. The real signing
# happens in Taskfile's `sign`, after this bundle exists.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-debug}"
APP="$ROOT/dist/MakiDeskDocker.app"

swift build --package-path "$ROOT/Docker" -c "$CONFIG"
BIN_DIR="$(swift build --package-path "$ROOT/Docker" -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MakiDeskDocker" "$APP/Contents/MacOS/MakiDeskDocker"
cp "$ROOT/Docker/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

codesign --force --sign - "$APP" >/dev/null 2>&1
echo "$APP"
