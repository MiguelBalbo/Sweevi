#!/bin/zsh
# Compila em modo release e empacota em "Sweevi.app".
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="Sweevi.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Sweevi" "$APP/Contents/MacOS/Sweevi"
cp Branding/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Sweevi</string>
    <key>CFBundleDisplayName</key>
    <string>Sweevi</string>
    <key>CFBundleIdentifier</key>
    <string>local.sweevi</string>
    <key>CFBundleExecutable</key>
    <string>Sweevi</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Pronto: $PWD/$APP"
