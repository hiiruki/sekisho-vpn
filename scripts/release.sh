#!/bin/sh
# Publishes a GitHub release (DMG + appcast.xml) for the vX.Y.Z tag at HEAD; installed copies find it through Sparkle
# (SUFeedURL = releases/latest/download/appcast.xml). Normally run by .github/workflows/release.yml when a signed tag
# is pushed. Needs `gh` auth and the Sparkle EdDSA private key: SPARKLE_KEY_FILE, else the login keychain.
set -e
cd "$(dirname "$0")/.."
REPO=hiiruki/sekisho-vpn
scripts/make-dmg.sh
VERSION=$(plutil -extract CFBundleShortVersionString raw build/app.noindex/Sekisho.app/Contents/Info.plist)
OUT=build/release
rm -rf "$OUT" && mkdir -p "$OUT"
cp "build/Sekisho-$VERSION.dmg" "$OUT/"
# notes from the Conventional Commits since the previous tag: an HTML fragment next to the DMG is embedded in the
# appcast (Sparkle's update dialog), the Markdown goes to the GitHub release with the DMG's SHA-256
scripts/release-notes.sh html > "$OUT/Sekisho-$VERSION.html"
NOTES=build/release-notes.md
{
  scripts/release-notes.sh md
  echo "SHA-256 \`$(shasum -a 256 "$OUT/Sekisho-$VERSION.dmg" | cut -d' ' -f1)\`  Sekisho-$VERSION.dmg"
} > "$NOTES"
# feed holds only this version: Sparkle just needs the newest item
.build/artifacts/sparkle/Sparkle/bin/generate_appcast ${SPARKLE_KEY_FILE:+--ed-key-file "$SPARKLE_KEY_FILE"} \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" "$OUT"
# --verify-tag: release only a pushed (signed) tag; gh would otherwise create an unsigned one
gh release create "v$VERSION" "$OUT/Sekisho-$VERSION.dmg" "$OUT/appcast.xml" --repo "$REPO" --title "Sekisho $VERSION" \
  --notes-file "$NOTES" --verify-tag
