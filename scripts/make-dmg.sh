#!/bin/sh
# Builds build/Sekisho-<version>.dmg: drag-and-drop installer (app + Applications link + background).
set -e
cd "$(dirname "$0")/.."
scripts/build-app.sh

VOL="Sekisho"
VERSION=$(plutil -extract CFBundleShortVersionString raw build/app.noindex/Sekisho.app/Contents/Info.plist)
DMG=build/Sekisho-$VERSION.dmg
RW=build/rw.dmg
STAGE=build/dmg
rm -rf "$STAGE" "$DMG" "$RW" build/*.dmg
mkdir -p "$STAGE/.background"
cp -R build/app.noindex/Sekisho.app "$STAGE/Sekisho.app"
ln -s /Applications "$STAGE/Applications"
# 1x + 2x merged into one HiDPI TIFF so Finder draws it sharp at window size
tiffutil -cathidpicheck build/art/dmg_background.png build/art/dmg_background@2x.png -out "$STAGE/.background/background.tiff" >/dev/null

hdiutil detach "/Volumes/$VOL" -quiet 2>/dev/null || true
hdiutil create -quiet -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ -format UDRW -ov "$RW"
DEV=$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk '/Apple_HFS/ {print $1}')

# Window layout is cosmetic: if Finder automation is denied, the DMG still works unarranged.
osascript <<EOF || echo "warning: Finder layout skipped (allow Automation for your terminal to get the styled window)"
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 120, 840, 520}
    set opts to icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set background picture of opts to file ".background:background.tiff"
    set position of item "Sekisho.app" of container window to {160, 175}
    set position of item "Applications" of container window to {480, 175}
    -- only seen with "show hidden files" on; park them outside the window
    repeat with n in {".background", ".fseventsd", ".Trashes", ".DS_Store"}
      try
        set position of item n of container window to {800, 800}
      end try
    end repeat
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF

sync
hdiutil detach "$DEV" -quiet
hdiutil convert "$RW" -quiet -format UDZO -imagekey zlib-level=9 -o "$DMG"
rm -rf "$RW" "$STAGE"
echo "Built $DMG"
