#!/bin/zsh
# Pinned official native runtime; no Python installation or model weights bundled.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/signing.sh
LITERT_TAG=v0.19.1
LITERT_SHA=cedd331e78e94bf98ca8f2f28aeb3d543e20277fcd51570c12deed6d49524fb6
LITERT_CACHE="$PWD/.build/litert-runtime/$LITERT_TAG"
LITERT_ARCHIVE="$LITERT_CACHE/runtime.zip"
LITERT_APP="${1:-$PWD/dist/Buffera.app}"
LITERT_DEST="$LITERT_APP/Contents/Frameworks/BufferaLiteRT"
mkdir -p "$LITERT_CACHE" "$LITERT_DEST" "$LITERT_APP/Contents/Resources/LiteRT"
if [[ ! -f "$LITERT_ARCHIVE" ]]; then
  curl --fail --location --retry 3 "https://github.com/google-ai-edge/LiteRT-LM/releases/download/$LITERT_TAG/CLiteRTLM_mac.xcframework.zip" -o "$LITERT_ARCHIVE.part"
  mv "$LITERT_ARCHIVE.part" "$LITERT_ARCHIVE"
fi
[[ "$(shasum -a 256 "$LITERT_ARCHIVE" | cut -d ' ' -f 1)" == "$LITERT_SHA" ]] || { print -u2 'LiteRT archive checksum mismatch'; exit 1; }
unzip -qo "$LITERT_ARCHIVE" -d "$LITERT_CACHE"
LITERT_FRAMEWORK="$LITERT_CACHE/CLiteRTLM_mac.xcframework/macos-arm64_x86_64"
rm -f "$LITERT_DEST/libCLiteRTLM_mac.dylib"
cp "$LITERT_FRAMEWORK/libCLiteRTLM_mac.dylib" "$LITERT_DEST/"
chmod u+w "$LITERT_DEST/libCLiteRTLM_mac.dylib"
for ROLE in Embedding Chat; do
  clang++ -std=c++17 -O2 -fobjc-arc -arch arm64 -mmacosx-version-min=14.0 \
    -I "$LITERT_FRAMEWORK/Headers" "Sources/BufferaModelRuntime/LiteRT${ROLE}Worker.mm" \
    -framework Foundation "$LITERT_DEST/libCLiteRTLM_mac.dylib" \
    -Wl,-rpath,@executable_path/../Frameworks/BufferaLiteRT \
    -o "$LITERT_APP/Contents/MacOS/BufferaLiteRT${ROLE}Worker"
done
# The distribution's license texts travel with the library.
find "$LITERT_CACHE/CLiteRTLM_mac.xcframework" -type f \( -iname '*license*' -o -iname '*notice*' \) -exec cp {} "$LITERT_APP/Contents/Resources/LiteRT/" \;
cp Sources/BufferaModelRuntime/LiteRT-NOTICE.txt "$LITERT_APP/Contents/Resources/LiteRT/"
buffera_sign_code "$LITERT_DEST/libCLiteRTLM_mac.dylib" library local.buffera.app.litert
for ROLE in Embedding Chat; do
  buffera_sign_code "$LITERT_APP/Contents/MacOS/BufferaLiteRT${ROLE}Worker" executable "local.buffera.app.litert-${ROLE:l}"
done
