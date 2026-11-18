#!/bin/zsh
# Builds LogosBar.app and installs it in ~/Applications.
#   --universal   build for both Apple Silicon and Intel (used by make-dmg.sh)
#   --no-install  leave the app in build/ instead of installing it
set -euo pipefail
cd "${0:A:h}"

universal=false install=true
for arg in "$@"; do
    case $arg in
        --universal) universal=true ;;
        --no-install) install=false ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

app="build/LogosBar.app"
rm -rf build
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Icon/AppIcon.icns "$app/Contents/Resources/"

if $universal; then
    for arch in arm64 x86_64; do
        swiftc -O -target "$arch-apple-macos14.0" -o "build/LogosBar-$arch" *.swift
    done
    lipo -create -output "$app/Contents/MacOS/LogosBar" build/LogosBar-arm64 build/LogosBar-x86_64
    rm build/LogosBar-arm64 build/LogosBar-x86_64
else
    swiftc -O -o "$app/Contents/MacOS/LogosBar" *.swift
fi

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.logosbar</string>
    <key>CFBundleName</key><string>LogosBar</string>
    <key>CFBundleExecutable</key><string>LogosBar</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.9</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Sign with the self-signed "LogosBar Signing" certificate when it's in the keychain, so macOS
# keeps LogosBar's Accessibility and Screen Recording permissions across rebuilds. It isn't
# trusted by the system, so look it up by hash rather than by name.
identity=$(security find-identity -p codesigning | awk '/"LogosBar Signing"/ { print $2; exit }')
if [[ -z "$identity" ]]; then
    echo "LogosBar Signing certificate not found; signing ad hoc (permissions reset on every rebuild)"
    identity=-
fi
codesign --force --sign "$identity" --identifier local.logosbar "$app"
$install || { echo "Built $app"; exit 0; }

mkdir -p ~/Applications
pkill -x LogosBar 2>/dev/null || true
rm -rf ~/Applications/LogosBar.app
cp -R "$app" ~/Applications/
echo "Installed ~/Applications/LogosBar.app"
