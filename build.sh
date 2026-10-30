#!/bin/zsh
# Builds PhotoShrink.app (universal: Apple Silicon + Intel). Needs only Xcode Command Line Tools.
set -e
cd "$(dirname "$0")"
APP=build/PhotoShrink.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for ARCH in arm64 x86_64; do
  swiftc -O -wmo -parse-as-library -swift-version 5 \
    -target $ARCH-apple-macos13.0 \
    Sources/*.swift -o build/PhotoShrink-$ARCH
done
lipo -create build/PhotoShrink-arm64 build/PhotoShrink-x86_64 -output "$APP/Contents/MacOS/PhotoShrink"
rm build/PhotoShrink-*

cp Resources/Info.plist "$APP/Contents/"
cp -R Resources/en.lproj Resources/uk.lproj "$APP/Contents/Resources/"
swift Resources/MakeIcon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf build/AppIcon.iconset

codesign --force --deep -s - "$APP"
echo "Done: $APP"
