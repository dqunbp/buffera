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
BIN_DIR=$(swift build --build-system native --disable-sandbox --scratch-path "$BUILD_PATH" --cache-path "$PWD/.build/cache" --show-bin-path)
CHECK_DIR="$BUILD_PATH/localized-panel-checks"
mkdir -p "$CHECK_DIR"
cp -R "$BIN_DIR/Buffera_BufferaLocalization.bundle" "$CHECK_DIR/"
# Share a single localization module between the fixture library and executable.
swiftc -emit-library "$BIN_DIR"/BufferaLocalization.build/*.swift.o -o "$CHECK_DIR/libBufferaLocalization.dylib"
swiftc -emit-library -emit-module -module-name BufferaCore \
  -I "$BIN_DIR/Modules" -L "$CHECK_DIR" -lBufferaLocalization \
  -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  Sources/BufferaCore/Clip.swift Sources/BufferaCore/ClipboardText.swift \
  Sources/BufferaCore/TextTransformation.swift Sources/BufferaCore/SearchMode.swift \
  -emit-module-path "$CHECK_DIR/BufferaCore.swiftmodule" -o "$CHECK_DIR/libBufferaCore.dylib"
targets=("$@")
if (( ${#targets[@]} == 0 )); then targets=(HistoryPanelChecks HistoryCardsChecks ClipDragChecks); fi
for test in "${targets[@]}"; do
swiftc -I "$CHECK_DIR" -I "$BIN_DIR/Modules" -L "$CHECK_DIR" -lBufferaCore -lBufferaLocalization \
  -Xlinker -rpath -Xlinker "$CHECK_DIR" -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  Sources/Buffera/HistoryPanel.swift Sources/Buffera/CopyTransformOperation.swift \
  Sources/Buffera/CopyTransformMenu.swift Sources/Buffera/NearbyHistoryState.swift \
  Sources/Buffera/HistoryShortcutGesture.swift Sources/Buffera/HistoryCardsView.swift \
  Sources/Buffera/ClipCardView.swift Sources/Buffera/ClipDragController.swift \
  Sources/Buffera/ClipDragPayload.swift Sources/Buffera/TemporaryImageExports.swift Sources/Buffera/HistoryFilters.swift \
  Sources/Buffera/HistoryAppearance.swift Sources/Buffera/InterfaceTheme.swift Sources/Buffera/BrandIdentity.swift \
  Sources/Buffera/LegacyMigration.swift Sources/Buffera/ClipPreview.swift \
  Sources/Buffera/ClipboardService.swift Sources/Buffera/ClipboardSessionMonitor.swift "Tests/$test/"*.swift \
  -o "$CHECK_DIR/$test"
"$CHECK_DIR/$test" -interfaceLanguage ru -AppleLanguages "(ru)"
if [[ "$test" != HistoryCardsChecks ]]; then
  "$CHECK_DIR/$test" -interfaceLanguage en -AppleLanguages "(en)"
fi
done
