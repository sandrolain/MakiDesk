#!/usr/bin/env bash
set -euo pipefail

# Fetches the GhosttyKit.xcframework used by the terminal spike.
#
# Provenance: cmux publishes prebuilt universal xcframeworks from its Ghostty
# fork (MIT, like Ghostty itself) and pins each archive by SHA-256 in
# refs/cmux-main/scripts/ghosttykit-checksums.txt. This script pins the
# combined classic build used by the study and never overwrites a local build
# that a developer put in vendor/ on purpose.
#
# The archive stays out of git: vendor/ is ignored. `swift build` at the
# repository root does not need it; only Terminal/Package.swift does.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GHOSTTY_SHA="cb1ef7091cdef0b581ee2cbd83742b653253523e"
FLAVOUR="crashsubdir-cmux-crash-sentry-off-noi18n-v2"
EXPECTED_SHA256="413515af9e3739068f91bae98bc33fa1d89d4ea20b35d0fa96b317379bb17ae2"
DEST="$ROOT/vendor/GhosttyKit.xcframework"

if [ -d "$DEST" ]; then
  echo "GhosttyKit already present at $DEST"
  exit 0
fi

URL="https://github.com/manaflow-ai/ghostty/releases/download/xcframework-${GHOSTTY_SHA}-${FLAVOUR}/GhosttyKit.xcframework.tar.gz"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/makidesk-ghosttykit.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

echo "Fetching GhosttyKit for ${GHOSTTY_SHA:0:10}..."
curl -fSL --connect-timeout 15 --max-time 600 --retry 3 --retry-delay 2 \
  -o "$TMP/GhosttyKit.xcframework.tar.gz" "$URL"

ACTUAL="$(shasum -a 256 "$TMP/GhosttyKit.xcframework.tar.gz" | awk '{print $1}')"
if [ "$ACTUAL" != "$EXPECTED_SHA256" ]; then
  echo "Checksum mismatch" >&2
  echo "  expected: $EXPECTED_SHA256" >&2
  echo "  actual:   $ACTUAL" >&2
  exit 1
fi

mkdir -p "$ROOT/vendor"
tar --no-same-owner -xzf "$TMP/GhosttyKit.xcframework.tar.gz" -C "$ROOT/vendor"
echo "GhosttyKit ready at $DEST"
