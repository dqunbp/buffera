#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
swift build -c release --product Bufera --cache-path "$PWD/.build/cache" "$@"
APP="$PWD/dist/Bufera.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Bufera "$APP/Contents/MacOS/Bufera"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.bufera.app</string>
<key>CFBundleName</key><string>Bufera</string>
<key>CFBundleDisplayName</key><string>Bufera</string>
<key>CFBundleExecutable</key><string>Bufera</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
# Finder / file-provider metadata on an existing local bundle invalidates strict signing.
xattr -dr com.apple.FinderInfo "$APP" 2>/dev/null || true
find "$APP" -name '._*' -type f -delete
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
printf 'Built %s\n' "$APP"
