#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/long_brackets.lua"
WAT="$BUILD_DIR/long_brackets.wat"
WASM="$BUILD_DIR/long_brackets.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features -o "$WASM" "$WAT"

EXPECTED=" plain 
2

 outer ]] 
 a ]] b ]=] c 
 deep ]====] 
no leading newline
also stripped
a
b
c
alpha
beta
gamma
delta
epsilon
paren-less
also works"

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
echo "ok: long_brackets matches"
