#!/bin/zsh
# Builds LogosBar.app and installs it in ~/Applications.
set -euo pipefail
cd "${0:A:h}"

app="build/LogosBar.app"
rm -rf build
mkdir -p "$app/Contents/MacOS"

swiftc -O -o "$app/Contents/MacOS/LogosBar" *.swift

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.logosbar</string>
    <key>CFBundleName</key><string>LogosBar</string>
    <key>CFBundleExecutable</key><string>LogosBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
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

mkdir -p ~/Applications
pkill -x LogosBar 2>/dev/null || true
rm -rf ~/Applications/LogosBar.app
cp -R "$app" ~/Applications/
echo "Installed ~/Applications/LogosBar.app"
