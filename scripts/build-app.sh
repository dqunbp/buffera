#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
swift build -c release --product Buffera --cache-path "$PWD/.build/cache" "$@"
swift build -c release --product BufferaMCP --cache-path "$PWD/.build/cache" "$@"
APP="$PWD/dist/Buffera.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Resources/SQLiteVec"
cp Sources/CSQLiteVec/LICENSE-* Sources/CSQLiteVec/README.md "$APP/Contents/Resources/SQLiteVec/"
cp .build/release/Buffera "$APP/Contents/MacOS/Buffera"
cp .build/release/BufferaMCP "$APP/Contents/MacOS/BufferaMCP"
if [[ "$(uname -m)" == arm64 ]]; then
  zsh scripts/prepare-model-runtime.sh "$APP"
fi
swiftc Sources/Buffera/BrandIdentity.swift scripts/generate-app-icon.swift \
  -o .build/generate-app-icon
.build/generate-app-icon "$PWD/.build/Buffera.iconset"
iconutil -c icns "$PWD/.build/Buffera.iconset" -o "$APP/Contents/Resources/Buffera.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.buffera.app</string>
<key>CFBundleName</key><string>Buffera</string>
<key>CFBundleDisplayName</key><string>Buffera</string>
<key>CFBundleIconFile</key><string>Buffera.icns</string>
<key>CFBundleExecutable</key><string>Buffera</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
# Finder / file-provider metadata on an existing local bundle invalidates strict signing.
xattr -dr com.apple.FinderInfo "$APP" 2>/dev/null || true
find "$APP" -name '._*' -type f -delete
codesign --force --sign - "$APP/Contents/MacOS/BufferaMCP"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
printf 'Built %s\n' "$APP"
