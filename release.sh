#!/bin/zsh
# Publishes a new version to GitHub Releases. The app's auto-updater picks it up.
# Usage: ./release.sh 1.1.0
set -e
cd "$(dirname "$0")"

VER="$1"
if [[ ! "$VER" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  echo "Usage: ./release.sh 1.2.3"; exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Commit or stash your changes first."; exit 1
fi
if git rev-parse "v$VER" >/dev/null 2>&1; then
  echo "Tag v$VER already exists."; exit 1
fi

# Bump version in Info.plist
PB=/usr/libexec/PlistBuddy
$PB -c "Set :CFBundleShortVersionString $VER" Resources/Info.plist
BUILD=$(( $($PB -c "Print :CFBundleVersion" Resources/Info.plist) + 1 ))
$PB -c "Set :CFBundleVersion $BUILD" Resources/Info.plist

./build.sh
ZIP="build/PhotoShrink-$VER.zip"
ditto -c -k --keepParent build/PhotoShrink.app "$ZIP"

git commit -am "Release v$VER" || true
git tag "v$VER"
git push origin HEAD
git push origin "v$VER"
gh release create "v$VER" "$ZIP" --title "PhotoShrink $VER" --generate-notes
echo "Released v$VER"
