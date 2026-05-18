#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/bitwise.lua"
WAT="$BUILD_DIR/bitwise.wat"
WASM="$BUILD_DIR/bitwise.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features -o "$WASM" "$WAT"

EXPECTED=$'0
240
65280
0
255
255
0
15
0
85
-1
0
-256
1
2
16
256
224
64
15
15
0
2
32
0
0
0
0
3
5
6
255
2
4
-4
false\tnil
false\tnil
false\tnil
false\tnil
band\tband
bor\tbor
bxor\tbxor
shl\tshl
shr\tshr
bnot
integer
integer
integer
integer'

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
echo "ok: bitwise matches"
