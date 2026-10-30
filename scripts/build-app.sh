#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/version.sh
source scripts/signing.sh
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
BUILD_PATH="${BUFFERA_BUILD_PATH:-$PWD/.build}"
# A file provider can attach Finder metadata to an existing resource bundle
# between builds; SwiftPM signs that bundle before assembling the app.
if [[ -d "$BUILD_PATH/release/Buffera_BufferaLocalization.bundle" ]]; then
  xattr -dr com.apple.FinderInfo "$BUILD_PATH/release/Buffera_BufferaLocalization.bundle" 2>/dev/null || true
fi
swift build -c release --product Buffera --scratch-path "$BUILD_PATH" --cache-path "$PWD/.build/cache" "$@"
swift build -c release --product BufferaMCP --scratch-path "$BUILD_PATH" --cache-path "$PWD/.build/cache" "$@"
BIN_DIR=$(swift build -c release --scratch-path "$BUILD_PATH" "$@" --show-bin-path)
# Sign outside file-provider-managed folders: FinderInfo may reappear while
# codesign is waiting for Apple's timestamp, even after removing it locally.
APP_STAGING=$(mktemp -d "${TMPDIR:-/tmp}/buffera-app-build.XXXXXX")
trap 'rm -rf "$APP_STAGING"' EXIT
APP="$APP_STAGING/Buffera.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Resources/SQLiteVec"
cp Sources/CSQLiteVec/LICENSE-* Sources/CSQLiteVec/README.md "$APP/Contents/Resources/SQLiteVec/"
cp "$BIN_DIR/Buffera" "$APP/Contents/MacOS/Buffera"
cp "$BIN_DIR/BufferaMCP" "$APP/Contents/MacOS/BufferaMCP"
# SwiftPM links Sparkle but does not embed its dynamic framework in our hand-built app.
SPARKLE_ROOT="$BUILD_PATH/artifacts/sparkle/Sparkle"
mkdir -p "$APP/Contents/Frameworks" "$APP/Contents/Resources/Sparkle"
ditto --norsrc --noextattr --noqtn \
  "$SPARKLE_ROOT/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" \
  "$APP/Contents/Frameworks/Sparkle.framework"
cp "$SPARKLE_ROOT/LICENSE" "$APP/Contents/Resources/Sparkle/"
SPARKLE_FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
# Buffera is not sandboxed. These optional services are neither enabled nor needed.
rm -rf "$SPARKLE_FRAMEWORK/XPCServices" "$SPARKLE_FRAMEWORK/Versions/B/XPCServices"
SPARKLE_PUBLIC_KEY=$(< scripts/sparkle-public-key.txt)
if [[ ! "$SPARKLE_PUBLIC_KEY" =~ '^[A-Za-z0-9+/]{43}=$' ]]; then
  print -u2 'Invalid Sparkle public key.'
  exit 1
fi
# SwiftPM build systems use different bundle layouts. Merging would retain an
# old Contents/Resources tree, which Foundation prefers over fresh flat resources.
rm -rf "$APP/Contents/Resources/Buffera_BufferaLocalization.bundle"
cp -R "$BIN_DIR/Buffera_BufferaLocalization.bundle" "$APP/Contents/Resources/"
if [[ "$(uname -m)" == arm64 ]]; then
  zsh scripts/prepare-model-runtime.sh "$APP"
fi
swiftc Sources/Buffera/BrandIdentity.swift scripts/generate-app-icon.swift \
  -o .build/generate-app-icon
.build/generate-app-icon "$PWD/.build/Buffera.iconset"
iconutil -c icns "$PWD/.build/Buffera.iconset" -o "$APP/Contents/Resources/Buffera.icns"
LOCALIZATIONS_PLIST=""
for locale_dir in Sources/BufferaLocalization/Resources/*.lproj; do
  locale_name="${locale_dir:t:r}"
  LOCALIZATIONS_PLIST+="<string>$locale_name</string>"
done
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.buffera.app</string>
<key>CFBundleName</key><string>Buffera</string>
<key>CFBundleDisplayName</key><string>Buffera</string>
<key>CFBundleIconFile</key><string>Buffera.icns</string>
<key>CFBundleExecutable</key><string>Buffera</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$BUFFERA_VERSION</string>
<key>CFBundleVersion</key><string>$BUFFERA_BUILD</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array>$LOCALIZATIONS_PLIST</array>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>SUFeedURL</key><string>https://github.com/dqunbp/buffera/releases/latest/download/appcast.xml</string>
<key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
<key>SUEnableAutomaticChecks</key><false/>
<key>SUAutomaticallyUpdate</key><false/>
<key>SUAllowsAutomaticUpdates</key><false/>
<key>SUEnableSystemProfiling</key><false/>
<key>SUVerifyUpdateBeforeExtraction</key><true/>
<key>SURequireSignedFeed</key><true/>
<key>SUSignedFeedFailureExpirationInterval</key><integer>0</integer>
</dict></plist>
PLIST
# Finder / file-provider metadata on an existing local bundle invalidates strict signing.
xattr -dr com.apple.FinderInfo "$APP" 2>/dev/null || true
find "$APP" -name '._*' -type f -delete
buffera_sign_code "$APP/Contents/MacOS/BufferaMCP" executable local.buffera.app.mcp
buffera_sign_code "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate" executable
buffera_sign_code "$SPARKLE_FRAMEWORK/Versions/B/Updater.app" executable
buffera_sign_code "$SPARKLE_FRAMEWORK" library
buffera_sign_code "$APP" executable
codesign --verify --deep --strict "$APP"
mkdir -p "$PWD/dist"
rm -rf "$PWD/dist/Buffera.app"
ditto --norsrc --noextattr --noqtn "$APP" "$PWD/dist/Buffera.app"
codesign --verify --deep --strict "$PWD/dist/Buffera.app"
printf 'Built %s\n' "$PWD/dist/Buffera.app"
