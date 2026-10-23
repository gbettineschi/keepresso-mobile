#!/bin/bash
set -euo pipefail
MACOS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$MACOS_ROOT/.." && pwd)"
# Native SwiftPM produces a statically linked executable using Command Line
# Tools. No Xcode project, installation, permissions or power test is needed.
swift build --package-path "$MACOS_ROOT" --build-system native -c release --product KeespressoMac
BIN_DIR="$(swift build --package-path "$MACOS_ROOT" --build-system native -c release --show-bin-path)"
APP="$MACOS_ROOT/artifacts/KeespressoMac.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/KeespressoMac" "$APP/Contents/MacOS/KeespressoMac"
cp "$REPO_ROOT/shared/assets/keepresso-installed-icon.png" "$APP/Contents/Resources/"
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
<key>CFBundleName</key><string>Keespresso Mac</string>
<key>CFBundleDisplayName</key><string>Keespresso Mac</string>
<key>CFBundleExecutable</key><string>KeespressoMac</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>NSBluetoothAlwaysUsageDescription</key><string>Connect to your authorized Keespresso phone nearby using encrypted Bluetooth messages.</string>
<key>NSBluetoothPeripheralUsageDescription</key><string>Share status and controls only with phones you explicitly authorize on this Mac.</string>
<key>NSHumanReadableCopyright</key><string>Unofficial companion. Original Keepresso artwork belongs to its author.</string>
</dict></plist>
PLIST
ICONSET="$MACOS_ROOT/.build/AppIcon.iconset"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
  sips -z "$SIZE" "$SIZE" "$REPO_ROOT/shared/assets/keepresso-installed-icon.png" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
  DOUBLE=$((SIZE * 2))
  sips -z "$DOUBLE" "$DOUBLE" "$REPO_ROOT/shared/assets/keepresso-installed-icon.png" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP"
"$APP/Contents/MacOS/KeespressoMac" --self-check
printf '%s\n' "$APP"
