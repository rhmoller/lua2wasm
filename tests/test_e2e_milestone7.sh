#!/usr/bin/env bash
set -euo pipefail

BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/milestone7.lua"
WAT="$BUILD_DIR/milestone7.wat"
WASM="$BUILD_DIR/milestone7.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features -o "$WASM" "$WAT"

EXPECTED="nil
boolean
number
number
string
table
function
42
nil
true
hi
42
-7
7
nil
3
-3
5
2.5
4.0
5
ell
ello
1
a
2
b
3
c
2"

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
echo "ok: milestone7 fixture matches"
