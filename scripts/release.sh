#!/bin/sh
# Publishes a GitHub release (DMG + appcast.xml); installed copies find it through Sparkle
# (SUFeedURL = releases/latest/download/appcast.xml). Bump VERSION and BUILD in build-app.sh first.
# Needs `gh auth login` and the Sparkle EdDSA private key in the login keychain (generate_keys, once per maintainer).
set -e
cd "$(dirname "$0")/.."
REPO=hiiruki/sekisho-vpn
scripts/make-dmg.sh
VERSION=$(plutil -extract CFBundleShortVersionString raw build/app.noindex/Sekisho.app/Contents/Info.plist)
OUT=build/release
rm -rf "$OUT" && mkdir -p "$OUT"
cp "build/Sekisho-$VERSION.dmg" "$OUT/"
# feed holds only this version: Sparkle just needs the newest item
.build/artifacts/sparkle/Sparkle/bin/generate_appcast --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" "$OUT"
gh release create "v$VERSION" "$OUT/Sekisho-$VERSION.dmg" "$OUT/appcast.xml" --repo "$REPO" --title "Sekisho $VERSION" --generate-notes
