#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/table_sort.lua"
WAT="$BUILD_DIR/table_sort.wat"
WASM="$BUILD_DIR/table_sort.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features -o "$WASM" "$WAT"

EXPECTED="1,1,2,3,3,4,5,5,6,9
9,6,5,5,4,3,3,2,1,1
apple,banana,cherry
z,ab,abc,abcd
1,2,3,4,5
1,2,3,4,5
42

5,5,5,5,5
true
false"

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
echo "ok: table_sort matches"
