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
  if [ -n "$SEKISHO_SIGNING_P12" ]; then # CI: the same identity as local builds, from a secret (base64 .p12, password "sekisho")
    printf %s "$SEKISHO_SIGNING_P12" | base64 --decode > "$TMP/id.p12"
  else
    # macOS's own LibreSSL: Homebrew's OpenSSL 3 (first in PATH on CI) writes a .p12 whose key `security import`
    # cannot read, and codesign then finds no identity
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$NAME" \
      -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
      -addext "basicConstraints=critical,CA:false" \
      -addext "keyUsage=critical,digitalSignature" \
      -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
    /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:sekisho
  fi
  security create-keychain -p "$PASS" "$KC"
  security set-keychain-settings "$KC" # no auto-lock
  security import "$TMP/id.p12" -k "$KC" -P sekisho -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KC" >/dev/null
  echo "Created $NAME in $KC" >&2
fi
security unlock-keychain -p "$PASS" "$KC"
# codesign reaches the private key only through the search list, even with --keychain
security list-keychains -d user | grep -q "$KC" || security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
echo "$KC"
