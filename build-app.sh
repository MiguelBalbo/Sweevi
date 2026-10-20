#!/bin/zsh
# Compila em modo release (universal: Apple Silicon + Intel) e empacota em "Sweevi.app".
# Funciona só com as Command Line Tools: cada arquitetura é compilada à parte e unida com lipo.
set -euo pipefail
cd "$(dirname "$0")"

# Mínimo: macOS 12 (Monterey).
# As Command Line Tools atuais não trazem a fatia Intel da biblioteca de compatibilidade do Swift
# (libswiftCompatibility56), exigida abaixo do macOS 13. Por isso a fatia Intel é compilada sem ela:
# abre no Monterey, mas fica sem as correções de concorrência que essa biblioteca aplica no 12.x.
BINARIES=()
for ARCH in arm64 x86_64; do
    echo "==> Compilando para $ARCH"
    FLAGS=(-c release --triple "$ARCH-apple-macosx12.0" --scratch-path ".build/$ARCH")
    if [[ "$ARCH" == x86_64 ]]; then
        FLAGS+=(-Xswiftc -runtime-compatibility-version -Xswiftc none)
    fi
    swift build "${FLAGS[@]}"
    BINARIES+=("$(swift build "${FLAGS[@]}" --show-bin-path)/Sweevi")
done

APP="Sweevi.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/Sweevi"
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
    <string>1.1</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Arquiteturas: $(lipo -archs "$APP/Contents/MacOS/Sweevi")"
echo "Pronto: $PWD/$APP"
