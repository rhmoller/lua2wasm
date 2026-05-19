#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/math_fillers.lua"
WAT="$BUILD_DIR/math_fillers.wat"
WASM="$BUILD_DIR/math_fillers.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features --disable-custom-descriptors -o "$WASM" "$WAT"

EXPECTED=$'1
-1
1
-1
0.0
1.0
0.0
false
3\t0.75
-3\t-0.75
0\t0.0
5\t0.0
5
5
nil
nil
nil
integer
float
nil
nil
nil
true
false
false
true
9223372036854775807
-9223372036854775808
true'

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
echo "ok: math_fillers matches"
