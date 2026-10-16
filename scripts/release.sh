#!/bin/sh
# Builds a release of Decibel and packages it for GitHub Releases: scripts/release.sh
# Writes dist/Decibel-<version>.dmg (drag-to-Applications) and .zip, plus SHA256SUMS.txt.
set -eu
cd "$(dirname "$0")/.."

archive=build/Decibel.xcarchive
xcodebuild archive -project Decibel.xcodeproj -scheme Decibel -configuration Release \
    -archivePath "$archive" -derivedDataPath build/DerivedData -quiet
app="$archive/Products/Applications/Decibel.app"
codesign --verify --deep --strict "$app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")

rm -rf dist
mkdir -p dist/dmg
ditto "$app" dist/dmg/Decibel.app
ln -s /Applications dist/dmg/Applications
hdiutil create -volname "Decibel $version" -srcfolder dist/dmg -fs HFS+ -format UDZO -ov "dist/Decibel-$version.dmg" -quiet
rm -rf dist/dmg
ditto -c -k --sequesterRsrc --keepParent "$app" "dist/Decibel-$version.zip"
cd dist
shasum -a 256 "Decibel-$version.dmg" "Decibel-$version.zip" > SHA256SUMS.txt
cat SHA256SUMS.txt
