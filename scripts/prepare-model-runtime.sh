#!/bin/zsh
# Bundle the official llama.cpp runtime, synthetic checker, and private model workers.
# Requires only Command Line Tools; Metal shaders are embedded in the upstream library.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -m)" != arm64 ]]; then
  print -u2 "Local models currently require Apple Silicon."
  exit 1
fi

RUNTIME_TAG=b11756
RUNTIME_REVISION=d80619397c2ba5cf1366c29f7d43699ca3a159b9
RUNTIME_SHA256=f86b5eb838b985a17587e794dee9c6b34193aca6dceec018031a4ba7951fb7e6
RUNTIME_CACHE="$PWD/.build/model-runtime/$RUNTIME_TAG"
RUNTIME_ARCHIVE="$RUNTIME_CACHE/llama-$RUNTIME_TAG-bin-macos-arm64.tar.gz"
RUNTIME_SOURCE="$RUNTIME_CACHE/llama-$RUNTIME_TAG"
RUNTIME_INCLUDE="$RUNTIME_CACHE/include"
APP_BUNDLE="${1:-$PWD/dist/Buffera.app}"
APP_RUNTIME="$APP_BUNDLE/Contents/Frameworks/BufferaModels"
APP_NOTICES="$APP_BUNDLE/Contents/Resources/ModelRuntime"
mkdir -p "$RUNTIME_CACHE" "$RUNTIME_INCLUDE" "$APP_RUNTIME" "$APP_NOTICES" "$APP_BUNDLE/Contents/MacOS"

if [[ ! -f "$RUNTIME_ARCHIVE" ]]; then
  curl --fail --location --retry 3 \
    "https://github.com/ggml-org/llama.cpp/releases/download/$RUNTIME_TAG/llama-$RUNTIME_TAG-bin-macos-arm64.tar.gz" \
    --output "$RUNTIME_ARCHIVE.part"
  mv "$RUNTIME_ARCHIVE.part" "$RUNTIME_ARCHIVE"
fi
ACTUAL_SHA256=$(shasum -a 256 "$RUNTIME_ARCHIVE" | cut -d ' ' -f 1)
if [[ "$ACTUAL_SHA256" != "$RUNTIME_SHA256" ]]; then
  print -u2 "Runtime checksum does not match. Remove $RUNTIME_ARCHIVE and rebuild."
  exit 1
fi
# Re-extract the verified archive instead of trusting a previously modified cache.
tar -xzf "$RUNTIME_ARCHIVE" -C "$RUNTIME_CACHE"

typeset -A HEADER_SHA256
HEADER_SHA256=(
  llama.h 961430f89e2553dbcd99e3e6c59826af9ec143f05911520c74f804d986ff3cd2
  ggml.h 475beaa7e959be8c383279d9ce9d5191f37426e6b338270cfb12b26a798129d3
  ggml-cpu.h 316279e004cdeb8e6ef78599acb602bf79a8abdf897fed9fd1914808c1518c6e
  ggml-backend.h 0e5e8e1f16d11ebbf501e38bc6705d79eee819b5f0b17476533f2100ed9674e2
  ggml-opt.h 3586de1bc8a934b5c72339e2b6937b0641e8f149b512231e666f67de0736eea2
  gguf.h e56714aab702e5ce62ee587a409643c08f7e93e8fbb77f48ef7cc85075f96fa4
  ggml-alloc.h d114067f9099c4a0e2bbc0625c676d4894d9cf0ea27168ee072c7de0e71bb51d
)
for HEADER in llama.h ggml.h ggml-cpu.h ggml-backend.h ggml-opt.h gguf.h ggml-alloc.h; do
  if [[ "$HEADER" == llama.h ]]; then
    HEADER_SOURCE="include/$HEADER"
  else
    HEADER_SOURCE="ggml/include/$HEADER"
  fi
  if [[ ! -s "$RUNTIME_INCLUDE/$HEADER" ]]; then
    curl --fail --location --retry 3 \
      "https://raw.githubusercontent.com/ggml-org/llama.cpp/$RUNTIME_REVISION/$HEADER_SOURCE" \
      --output "$RUNTIME_INCLUDE/$HEADER.part"
    mv "$RUNTIME_INCLUDE/$HEADER.part" "$RUNTIME_INCLUDE/$HEADER"
  fi
  if [[ "$(shasum -a 256 "$RUNTIME_INCLUDE/$HEADER" | cut -d ' ' -f 1)" != "${HEADER_SHA256[$HEADER]}" ]]; then
    print -u2 "Header checksum does not match: $RUNTIME_INCLUDE/$HEADER"
    exit 1
  fi
done

# Copy dereferenced dylibs with the exact install names referenced by libllama.
# RPC is a linked upstream dependency, but no RPC server executable is bundled or started.
for LIBRARY in llama ggml ggml-base ggml-cpu ggml-blas ggml-metal ggml-rpc; do
  cp -L "$RUNTIME_SOURCE/lib$LIBRARY.0.dylib" "$APP_RUNTIME/lib$LIBRARY.0.dylib"
done

clang++ -std=c++17 -O2 -arch arm64 -mmacosx-version-min=14.0 \
  -I "$RUNTIME_INCLUDE" Sources/BufferaModelRuntime/ModelProbe.cpp \
  -L "$APP_RUNTIME" -Wl,-rpath,@executable_path/../Frameworks/BufferaModels \
  -Wl,-rpath,@loader_path \
  "$APP_RUNTIME/libllama.0.dylib" "$APP_RUNTIME/libggml.0.dylib" "$APP_RUNTIME/libggml-base.0.dylib" \
  -o "$APP_BUNDLE/Contents/MacOS/BufferaModelProbe"

clang++ -std=c++17 -O2 -fobjc-arc -arch arm64 -mmacosx-version-min=14.0 \
  -I "$RUNTIME_INCLUDE" Sources/BufferaModelRuntime/EmbeddingWorker.mm \
  -framework Foundation \
  -L "$APP_RUNTIME" -Wl,-rpath,@executable_path/../Frameworks/BufferaModels \
  -Wl,-rpath,@loader_path \
  "$APP_RUNTIME/libllama.0.dylib" "$APP_RUNTIME/libggml.0.dylib" "$APP_RUNTIME/libggml-base.0.dylib" \
  -o "$APP_BUNDLE/Contents/MacOS/BufferaEmbeddingWorker"

clang++ -std=c++17 -O2 -fobjc-arc -arch arm64 -mmacosx-version-min=14.0 \
  -I "$RUNTIME_INCLUDE" Sources/BufferaModelRuntime/ChatWorker.mm \
  -framework Foundation \
  -L "$APP_RUNTIME" -Wl,-rpath,@executable_path/../Frameworks/BufferaModels \
  -Wl,-rpath,@loader_path \
  "$APP_RUNTIME/libllama.0.dylib" "$APP_RUNTIME/libggml.0.dylib" "$APP_RUNTIME/libggml-base.0.dylib" \
  -o "$APP_BUNDLE/Contents/MacOS/BufferaChatWorker"

cp "$RUNTIME_SOURCE/LICENSE" "$APP_NOTICES/llama.cpp-LICENSE.txt"
"$RUNTIME_SOURCE/llama" licenses > "$APP_NOTICES/THIRD-PARTY-NOTICES.txt"
cat > "$APP_NOTICES/runtime.txt" <<NOTICE
llama.cpp $RUNTIME_TAG ($RUNTIME_REVISION)
https://github.com/ggml-org/llama.cpp/releases/tag/$RUNTIME_TAG
Runtime archive SHA-256: $RUNTIME_SHA256
Official macOS arm64 binaries. The probe uses fixed synthetic checks.
The embedding and chat workers process text locally over anonymous stdin/stdout pipes.
Model weights are downloaded separately and are not included in this application.
NOTICE

for LIBRARY in "$APP_RUNTIME"/*.dylib; do
  codesign --force --sign - "$LIBRARY"
done
codesign --force --sign - "$APP_BUNDLE/Contents/MacOS/BufferaModelProbe"
codesign --force --sign - "$APP_BUNDLE/Contents/MacOS/BufferaEmbeddingWorker"
codesign --force --sign - "$APP_BUNDLE/Contents/MacOS/BufferaChatWorker"
print "Prepared local model runtime: $APP_BUNDLE"
