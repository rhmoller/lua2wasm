#!/usr/bin/env bash
set -euo pipefail

# Args: <lua2wasm-bin> <source-dir> <build-dir>
BIN="$1"
SRC_DIR="$2"
BUILD_DIR="$3"

FIXTURE="$SRC_DIR/tests/fixtures/print_sum.lua"
WAT="$BUILD_DIR/print_sum.wat"
WASM="$BUILD_DIR/print_sum.wasm"

"$BIN" "$FIXTURE" -o "$WAT"

# Assemble the WAT to a binary module with our own wat2wasm.
"$BUILD_DIR/wat2wasm" -o "$WASM" "$WAT"

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "3" ]]; then
    echo "FAIL: expected '3', got '$OUT'" >&2
    exit 1
fi
echo "ok: print(1+2) -> $OUT"
