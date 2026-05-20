#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/math_atan_log.lua"
WAT="$BUILD_DIR/math_atan_log.wat"
WASM="$BUILD_DIR/math_atan_log.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features --disable-custom-descriptors -o "$WASM" "$WAT"

EXPECTED="3.1415926535897931
0.0
0.0
1.5707963267948966
-1.5707963267948966
3.1415926535897931
3.1415926535897931
0.0
1.0
3.0
2.0
0.0
3.0"

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
echo "ok: math_atan_log matches"
