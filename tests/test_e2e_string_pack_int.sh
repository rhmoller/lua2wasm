#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/string_pack_int.lua"
WAT="$BUILD_DIR/string_pack_int.wat"
WASM="$BUILD_DIR/string_pack_int.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features --disable-custom-descriptors -o "$WASM" "$WAT"

EXPECTED=$'0\t2
-1\t2
127\t2
-128\t2
0\t3
-1\t3
32767\t3
-32768\t3
-1\t5
2147483647\t5
-2147483648\t5
-1\t2
-1\t4
8388607\t4
-8388608\t4
-1\t9
-1\t9
255
255\t255\t255\t254
-2\t5
-1\t200\t-1000\t5
false\tnil
false\tnil
false\tnil
false\tnil
false\tnil
false\tnil
8\t-1\t-2\t9'

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
