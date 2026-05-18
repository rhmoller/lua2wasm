#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/hex_literals.lua"
WAT="$BUILD_DIR/hex_literals.wat"
WASM="$BUILD_DIR/hex_literals.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features -o "$WASM" "$WAT"

EXPECTED="255
255
255
51966
16
0
integer
integer
8.0
1.5
3.0
0.5
10.6875
4.0
float
float
integer
256
32
15
15
-255
11259375
11259375"

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
echo "ok: hex_literals matches"
