#!/usr/bin/env bash
# Lua strings are raw byte arrays. This guards that non-UTF-8 bytes survive
# print/io.write/string.format byte-for-byte (the host must not UTF-8 re-encode
# them). Binary output can't go through the shell-string golden comparison used
# by run.sh, so compare bytes with cmp against a committed reference capture.
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIX="$SRC_DIR/tests/fixtures/binary_string.lua"
WASM="$BUILD_DIR/binary_string.wasm"
GOLDEN="$SRC_DIR/tests/e2e/expected/binary_string.bin"
"$BIN" "$FIX" -o "$WASM"
node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM" > "$BUILD_DIR/binary_string.out"
if ! cmp -s "$GOLDEN" "$BUILD_DIR/binary_string.out"; then
    echo "FAIL: binary output mismatch" >&2
    echo "--- expected ---" >&2; od -An -tx1 "$GOLDEN" >&2
    echo "--- got ---"      >&2; od -An -tx1 "$BUILD_DIR/binary_string.out" >&2
    exit 1
fi
