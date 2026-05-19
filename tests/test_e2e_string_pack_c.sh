#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/string_pack_c.lua"
WAT="$BUILD_DIR/string_pack_c.wat"
WASM="$BUILD_DIR/string_pack_c.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features --disable-custom-descriptors -o "$WASM" "$WAT"

EXPECTED=$'abcd\t5
Z\t2
10
0
97\t98\t0\t0
104\t101\t108\t108\t111\t0\t0\t0\t0\t0
0
1
true
4
5
7\txyz\t9\t6
false\tnil
7\tabc\t8\t6
false\tstring_pack_c:44: missing size'

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
