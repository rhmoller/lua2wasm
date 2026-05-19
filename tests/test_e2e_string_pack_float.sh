#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/string_pack_float.lua"
WAT="$BUILD_DIR/string_pack_float.wat"
WASM="$BUILD_DIR/string_pack_float.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features --disable-custom-descriptors -o "$WASM" "$WAT"

EXPECTED=$'4
8
8
0.0\t9
1.0\t9
-1.0\t9
0.5\t9
1.5\t9
42.5\t9
1.0\t5
-0.5\t5
256.0\t5
inf\t9
-inf\t9
inf\t5
42.0\t9
0\t0\t128\t63
63\t128\t0\t0
0\t63
63\t0
8
true
16
1\t2.5\t17'

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
