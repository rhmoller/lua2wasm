#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/string_pack_uint.lua"
WAT="$BUILD_DIR/string_pack_uint.wat"
WASM="$BUILD_DIR/string_pack_uint.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features -o "$WASM" "$WAT"

EXPECTED=$'1
2
4
1
8
8
8
8
52\t18
200\t2
43981\t3
305419896\t5
11259375\t4
255\t2
72623859790382856\t9
9128161956862029837\t9
1\t256\t65536\t8
8\t3
8\t9\t4
3\t0
7\t9\t4
4\t3\t2\t1
1\t2\t3\t4
16909060\t5
16909060\t5
16909060\t5
8
7\t0\t0\t0
7\t255\t9
5
1\t9\t6
false\tnil
false\tnil
false\tnil
false\tnil
false\tnil
false\tnil
false\tnil'

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
