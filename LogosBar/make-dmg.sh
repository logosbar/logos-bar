#!/bin/zsh
# Builds LogosBar for Apple Silicon and Intel and packages it as build/LogosBar-<version>.dmg,
# with an Applications shortcut to drag the app onto. Doesn't touch the installed copy.
set -euo pipefail
cd "${0:A:h}"

./build.sh --universal --no-install

app="build/LogosBar.app"
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")
dmg="build/LogosBar-$version.dmg"

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"

hdiutil create -quiet -volname "LogosBar" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg"

# Sign the disk image with the same certificate as the app, when it's available.
identity=$(security find-identity -p codesigning | awk '/"LogosBar Signing"/ { print $2; exit }')
[[ -n "$identity" ]] && codesign --force --sign "$identity" "$dmg"

echo "Made $dmg"
