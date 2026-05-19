#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/globals_G.lua"
WAT="$BUILD_DIR/globals_G.wat"
WASM="$BUILD_DIR/globals_G.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features --disable-custom-descriptors -o "$WASM" "$WAT"

EXPECTED=$'true
table
42
100
true
hello via _G
1
OK
OVERRIDE:\tfirst
restored
via _G:\tfrom _G
Lua 5.5
true
true
99
nil
nil
nil'

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
echo "ok: globals_G matches"
