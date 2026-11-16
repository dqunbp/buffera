#!/bin/zsh
# Exercise the production framing, input limits and text escaping without weights or a GPU.
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/buffera-litert-checks.XXXXXX")
trap 'rm -rf "$CHECK_DIR"' EXIT
clang++ -std=c++17 -fobjc-arc -mmacosx-version-min=14.0 \
  -I Sources/BufferaModelRuntime Tests/LiteRTWorkerChecks/main.mm \
  -framework Foundation -o "$CHECK_DIR/LiteRTWorkerChecks"
"$CHECK_DIR/LiteRTWorkerChecks"
