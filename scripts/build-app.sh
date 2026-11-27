#!/bin/sh
# Builds build/app.noindex/Sekisho.app, signed with the local "Sekisho Self-Signed" identity (created on first run).
# Needs only Command Line Tools.
# ".noindex" keeps Spotlight/Launchpad from listing this copy next to the installed one in /Applications.
set -e
cd "$(dirname "$0")/.."
# selftest needs a debug build (@testable), so build only the shipped products
swift build -c release --product SSTPClient
swift build -c release --product sstpd
BIN=$(swift build -c release --show-bin-path)
APP=build/app.noindex/Sekisho.app
VERSION=1.0.0 # user-facing; bump BUILD on every release
BUILD=1
SIGN_ID="Sekisho Self-Signed"
KC=$(scripts/make-signing-identity.sh)

rm -rf build/app.noindex # also drops apps built under older names
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/SSTPClient" "$APP/Contents/MacOS/"
cp "$BIN/sstpd" scripts/install-daemon.sh "$APP/Contents/Resources/"
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/SSTPClient"

# icon: render 1024px master, downscale into an .iconset, pack with iconutil
ART=build/art
rm -rf "$ART" && mkdir -p "$ART/AppIcon.iconset"
swift scripts/make-art.swift "$ART"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ART/icon_1024.png" --out "$ART/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$ART/icon_1024.png" --out "$ART/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ART/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>SSTPClient</string>
  <key>CFBundleIdentifier</key><string>moe.hiiruki.sekisho</string>
  <key>CFBundleName</key><string>Sekisho</string>
  <key>CFBundleDisplayName</key><string>Sekisho</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Hiiruki · hiiruki.moe</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>SUFeedURL</key><string>https://github.com/hiiruki/sekisho-vpn/releases/latest/download/appcast.xml</string>
  <key>SUPublicEDKey</key><string>ihtVbJ2XI0OMficqNIOKwJZu2gksfGDBJLqu2LDZjQM=</string>
  <key>NSLocationUsageDescription</key><string>Sekisho reads the Wi-Fi name to connect automatically outside your trusted networks.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>Sekisho reads the Wi-Fi name to connect automatically outside your trusted networks.</string>
</dict></plist>
EOF

# no hardened runtime: its library validation rejects frameworks without a Team ID, which self-signed code lacks
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for c in "$SPARKLE"/XPCServices/*.xpc "$SPARKLE/Autoupdate" "$SPARKLE/Updater.app" "$APP/Contents/Frameworks/Sparkle.framework"; do
  codesign --force --keychain "$KC" -s "$SIGN_ID" "$c"
done
codesign --force --keychain "$KC" -s "$SIGN_ID" -i moe.hiiruki.sekisho.helper "$APP/Contents/Resources/sstpd"
codesign --force --keychain "$KC" -s "$SIGN_ID" "$APP"
echo "Built $APP  (open it, then click 'Install Helper…' once)"
