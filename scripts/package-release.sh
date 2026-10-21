#!/bin/zsh
# Package the app produced by build-app.sh; never include local history or model weights.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$PWD/dist/Buffera.app"
DMG="$PWD/dist/Buffera-macOS-arm64.dmg"
if [[ ! -d "$APP" ]]; then
  print -u2 'Build the app first: zsh scripts/build-app.sh'
  exit 1
fi
if [[ "$(lipo -archs "$APP/Contents/MacOS/Buffera")" != arm64 ]]; then
  print -u2 'This release package requires an Apple Silicon (arm64) build.'
  exit 1
fi
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/buffera-release.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
mkdir "$STAGING/payload"
ditto --norsrc --noextattr --noqtn "$APP" "$STAGING/payload/Buffera.app"
codesign --verify --deep --strict "$STAGING/payload/Buffera.app"
ln -s /Applications "$STAGING/payload/Applications"
cp docs/INSTALL.txt "$STAGING/payload/README.txt"
hdiutil create -ov -format UDZO -volname "Buffera $VERSION" \
  -srcfolder "$STAGING/payload" "$DMG"
hdiutil verify "$DMG"
(cd dist && shasum -a 256 Buffera-macOS-arm64.dmg > SHA256SUMS.txt)
print "Packaged $DMG"
