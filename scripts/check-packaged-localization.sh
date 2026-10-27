#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
BUILD_PATH="${BUFFERA_BUILD_PATH:-$PWD/.build}"
if [[ -d "$BUILD_PATH/debug/Buffera_BufferaLocalization.bundle" ]]; then
  xattr -dr com.apple.FinderInfo "$BUILD_PATH/debug/Buffera_BufferaLocalization.bundle" 2>/dev/null || true
fi
swift build --build-system native --disable-sandbox --scratch-path "$BUILD_PATH" --cache-path "$PWD/.build/cache" --target BufferaLocalization
BIN_DIR=$(swift build --build-system native --disable-sandbox --scratch-path "$BUILD_PATH" --show-bin-path)
CHECK_ROOT=$(mktemp -d /private/tmp/BufferaPackagedLocalization.XXXXXX)
trap 'rm -rf "$CHECK_ROOT"' EXIT
APP="$CHECK_ROOT/Fixture.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp -R "$BIN_DIR/Buffera_BufferaLocalization.bundle" "$APP/Contents/Resources/"
swiftc -emit-library "$BIN_DIR"/BufferaLocalization.build/*.swift.o \
  -Xlinker -install_name -Xlinker @rpath/libBufferaLocalization.dylib \
  -o "$APP/Contents/Frameworks/libBufferaLocalization.dylib"
swiftc -I "$BIN_DIR/Modules" -L "$APP/Contents/Frameworks" -lBufferaLocalization \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  Tests/PackagedLocalizationChecks/main.swift -o "$APP/Contents/MacOS/Fixture"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.buffera.packaged-localization-check</string>
<key>CFBundleExecutable</key><string>Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
# A working build-directory fallback would hide a packaging regression.
# Deny the entire checkout, including SwiftPM's compiled-in absolute path.
cat > "$CHECK_ROOT/no-checkout.sb" <<'PROFILE'
(version 1)
(allow default)
(deny file-read* (subpath (param "CHECKOUT")))
(deny file-read* (subpath (param "BUILD")))
PROFILE
/usr/bin/sandbox-exec -D "CHECKOUT=$PWD" -D "BUILD=$BIN_DIR" \
  -f "$CHECK_ROOT/no-checkout.sb" "$APP/Contents/MacOS/Fixture"
