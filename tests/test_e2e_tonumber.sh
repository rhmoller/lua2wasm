#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/tonumber.lua"
WAT="$BUILD_DIR/tonumber.wat"
WASM="$BUILD_DIR/tonumber.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features --disable-custom-descriptors -o "$WASM" "$WAT"

EXPECTED="42
3.14
0
42
-7
5
3.14
-3.14
1000.0
0.015
0.5
5.0
16
255
-16
42
3.14
nil
nil
nil
nil
nil
nil
nil
nil
255
255
2
8
36
35
-16
nil
nil
nil
nil
nil
integer
float
integer
float
integer"

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
echo "ok: tonumber matches"
