#!/bin/bash
set -euo pipefail
MACOS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$MACOS_ROOT/.." && pwd)"
if [[ "$(uname -m)" != arm64 ]]; then
  echo 'This iroh integration package currently supports Apple silicon only.' >&2
  exit 2
fi
# Native SwiftPM produces a statically linked executable using Command Line
# Tools. No Xcode project, installation, permissions or power test is needed.
swift build --package-path "$MACOS_ROOT" --build-system native -c release --product KeepressoMac
BIN_DIR="$(swift build --package-path "$MACOS_ROOT" --build-system native -c release --show-bin-path)"
# Keep unpacked development bundles out of Spotlight/launcher discovery.
APP="${KEEPRESSO_APP_DESTINATION:-$MACOS_ROOT/.build/app-staging/KeepressoMobile.app}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Library/LaunchAgents"
cp "$MACOS_ROOT/Resources/local.keepresso.mobile.follow.plist" "$APP/Contents/Library/LaunchAgents/"
cp "$BIN_DIR/KeepressoMac" "$APP/Contents/MacOS/KeepressoMac"
cp "$REPO_ROOT/shared/assets/keepresso-mobile-mac-icon.png" "$APP/Contents/Resources/"
cp "$REPO_ROOT/shared/assets/keepresso-menu-idle.png" "$APP/Contents/Resources/"
# Companion-only resource locator uses the standard sealed app resource path.
CORE_RESOURCES="$APP/Contents/Resources/KeepressoCore.bundle"
mkdir -p "$CORE_RESOURCES"
cp -R "$MACOS_ROOT"/ThirdParty/KeepressoCore/Sources/*.lproj "$CORE_RESOURCES/"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleDevelopmentRegion</key><string>en</string></dict></plist>' > "$CORE_RESOURCES/Info.plist"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.keespresso.companion</string>
<key>CFBundleName</key><string>Keepresso Mobile</string>
<key>CFBundleDisplayName</key><string>Keepresso Mobile</string>
<key>CFBundleExecutable</key><string>KeepressoMac</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.6.12</string>
<key>CFBundleVersion</key><string>6012</string>
<key>LSMinimumSystemVersion</key><string>14.5</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>NSCalendarsFullAccessUsageDescription</key><string>Read event times for your configured calendar trigger. Event titles are not sent to your phone.</string>
<key>NSDocumentsFolderUsageDescription</key><string>Read activity metadata for configured folder and Steam download triggers. Downloaded file contents are not read.</string>
<key>NSDesktopFolderUsageDescription</key><string>Read activity metadata for configured folder and Steam download triggers. Downloaded file contents are not read.</string>
<key>NSRemovableVolumesUsageDescription</key><string>Read Steam activity metadata in your configured libraries. Downloaded file contents are not read.</string>
<key>NSNetworkVolumesUsageDescription</key><string>Read Steam activity metadata in your configured libraries. Downloaded file contents are not read.</string>
<key>NSDownloadsFolderUsageDescription</key><string>Check whether downloads are still being written for your configured trigger. File contents are not read.</string>
<key>NSBluetoothAlwaysUsageDescription</key><string>Connect to your authorized Keepresso phone nearby using encrypted Bluetooth messages.</string>
<key>NSBluetoothPeripheralUsageDescription</key><string>Share status and controls only with phones you explicitly authorize on this Mac.</string>
<key>NSLocationUsageDescription</key><string>Show your Mac's current Wi-Fi name on your paired phone. No coordinates are collected.</string>
<key>NSLocationWhenInUseUsageDescription</key><string>Show your Mac's current Wi-Fi name on your paired phone. No coordinates are collected.</string>
<key>NSHumanReadableCopyright</key><string>Unofficial companion. Original Keepresso artwork belongs to its author.</string>
</dict></plist>
PLIST
ICONSET="$MACOS_ROOT/.build/AppIcon.iconset"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
  sips -z "$SIZE" "$SIZE" "$REPO_ROOT/shared/assets/keepresso-mobile-mac-icon.png" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
  DOUBLE=$((SIZE * 2))
  sips -z "$DOUBLE" "$DOUBLE" "$REPO_ROOT/shared/assets/keepresso-mobile-mac-icon.png" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
bash "$MACOS_ROOT/scripts/sign-app.sh" "$APP"
"$APP/Contents/MacOS/KeepressoMac" --self-check
printf '%s\n' "$APP"
