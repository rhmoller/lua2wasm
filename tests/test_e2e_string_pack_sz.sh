#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/string_pack_sz.lua"
WAT="$BUILD_DIR/string_pack_sz.wat"
WASM="$BUILD_DIR/string_pack_sz.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features -o "$WASM" "$WAT"

EXPECTED=$'hello\t7
3
97\t98\t0
0
abc\t5
false\tnil
hello\t14
10
4
5
7
2
120\t121
false\tnil
2\t0
0\t2
hi\t5
hi\t5
5\t7\thi\t9\t6
9
1\tX\t10
false\tnil
false\tnil
6
ab\t52719\t7'

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
