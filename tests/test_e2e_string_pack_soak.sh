#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/string_pack_soak.lua"
WAT="$BUILD_DIR/string_pack_soak.wat"
WASM="$BUILD_DIR/string_pack_soak.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features -o "$WASM" "$WAT"

EXPECTED=$'171
2\t1
4\t3\t2\t1
3\t2\t1
8\t7\t6\t5\t4\t3\t2\t1
255
255\t255
255\t255\t255\t255
1\t0\t0\t0\t0\t0\t0\t1\t1\t0\t0\t0
63\t240\t0\t0\t0\t0\t0\t0
0\t0\t128\t63
104\t105\t0\t0\t0
104\t105\t0
2\t104\t105
0\t2\t104\t105
1\t0\t2
1\t0\t0\t0\t0\t0\t0\t0
1\t0\t0\t0\t9
19
24
15
16
12
58
-1\t65261\t3405691582\t305419896\t1.5\t3.25\tABCD\thello\thi\tworld\t200\t59
true
12
10\t65
20\t66
30\t67
40\t68
true
true
1\t0
1\t0'

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
