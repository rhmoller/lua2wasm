#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/math_table_lib.lua"
WAT="$BUILD_DIR/math_table_lib.wat"; WASM="$BUILD_DIR/math_table_lib.wasm"
"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features -o "$WASM" "$WAT"

EXPECTED="4
-1
5
3
7
2.5
5.5
3
a
c
c
2
a, b
x-y-z
a,b,c"
OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
echo "ok: math_table_lib matches"
