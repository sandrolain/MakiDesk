#!/bin/sh
# Creates a stable, self-signed code-signing identity for MakiDesk.
#
# Why: the default Taskfile signs the app ad-hoc, and an ad-hoc signature has no
# stable identity, so macOS treats every rebuild as a brand-new app and resets
# the Accessibility (TCC) permission. A self-signed certificate gives the app a
# stable Designated Requirement, so the permission survives rebuilds.
#
# Run once:  task cert     (or: sh scripts/setup-signing-cert.sh)
set -e

CERT_NAME="MakiDesk Local Signing"
KEYCHAIN="$HOME/Library/Keychains/makidesk-signing.keychain-db"
KEYCHAIN_PASS="makidesk"
OPENSSL="$(command -v openssl || echo /usr/bin/openssl)"

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "Signing identity '$CERT_NAME' already exists in $KEYCHAIN — nothing to do."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Generating self-signed code-signing certificate '$CERT_NAME'…"
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -subj "/CN=$CERT_NAME/O=MakiDesk/C=IT" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false" >/dev/null 2>&1

if [ ! -f "$KEYCHAIN" ]; then
    security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
fi
security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"

security import "$TMP/cert.pem" -k "$KEYCHAIN" -T /usr/bin/codesign -A >/dev/null
security import "$TMP/key.pem" -k "$KEYCHAIN" -T /usr/bin/codesign -A >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null 2>&1 || true

# Keep the new keychain in the user's search list alongside the existing ones.
EXISTING="$(security list-keychains -d user | tr -d ' "')"
if [ -z "$EXISTING" ]; then
    security list-keychains -d user -s "$HOME/Library/Keychains/login.keychain-db" "$KEYCHAIN"
elif ! echo "$EXISTING" | grep -q "makidesk-signing"; then
    security list-keychains -d user -s $EXISTING "$KEYCHAIN"
fi

echo "Done. '$CERT_NAME' is ready; 'task sign' will use it automatically."
echo "Note: the first build after switching identity needs the permission granted once."
