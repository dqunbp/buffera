#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
swift build --build-system native --disable-sandbox --cache-path "$PWD/.build/cache" --product Buffera
BIN_DIR=$(swift build --build-system native --disable-sandbox --cache-path "$PWD/.build/cache" --show-bin-path)
swiftc -I "$BIN_DIR/Modules" -I Sources/CSQLite -I Sources/CSQLiteVec/include \
  -Xcc -fmodule-map-file="$BIN_DIR/CSQLiteVec.build/module.modulemap" -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  "$BIN_DIR"/BufferaCore.build/*.swift.o "$BIN_DIR"/BufferaLocalization.build/*.swift.o "$BIN_DIR"/CSQLiteVec.build/*.o \
  Sources/Buffera/TextFileNaming.swift Sources/Buffera/CopyTransformOperation.swift Sources/Buffera/CopyTransformService.swift \
  Sources/Buffera/TemporaryImageExports.swift Sources/Buffera/ClipboardService.swift Sources/Buffera/ImageTextRecognizer.swift \
  Tests/CopyTransformServiceChecks/main.swift -o "$BIN_DIR/copy-transform-checks"
"$BIN_DIR/copy-transform-checks"
