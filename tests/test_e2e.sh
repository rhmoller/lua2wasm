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

# Binaryen's wasm-as supports the modern GC text format; the wabt shipped on
# Arch (1.0.39) still rejects `anyref` and recursive `(ref null $t)` refs.
wasm-as --all-features -o "$WASM" "$WAT"

OUT="$(node "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "3" ]]; then
    echo "FAIL: expected '3', got '$OUT'" >&2
    exit 1
fi
echo "ok: print(1+2) -> $OUT"
