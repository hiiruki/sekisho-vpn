#!/bin/sh
# Creates the local self-signed code signing identity build-app.sh uses ("Sekisho Self-Signed") in its own keychain
# and unlocks it. Prints the keychain path. A stable identity keeps the Keychain from asking again after every build
# and lets the helper verify the app. Not trusted by Gatekeeper: that would need a paid Developer ID.
# Own keychain, not login: the login keychain's partition list makes every codesign call ask for the key.
set -e
NAME="Sekisho Self-Signed"
KC="$HOME/Library/Keychains/sekisho-signing.keychain-db"
PASS=sekisho # guards nothing beyond the file's permissions: the key only signs this Mac's own builds

if [ ! -f "$KC" ]; then
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$NAME" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
  openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:sekisho
  security create-keychain -p "$PASS" "$KC"
  security set-keychain-settings "$KC" # no auto-lock
  security import "$TMP/id.p12" -k "$KC" -P sekisho -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KC" >/dev/null
  echo "Created $NAME in $KC" >&2
fi
security unlock-keychain -p "$PASS" "$KC"
echo "$KC"
