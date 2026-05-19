#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/metamethods_concat_len.lua"
WAT="$BUILD_DIR/metamethods_concat_len.wat"
WASM="$BUILD_DIR/metamethods_concat_len.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features --disable-custom-descriptors -o "$WASM" "$WAT"

EXPECTED=$'A:x
A:table
A:table
hi 42
12
99
7
5
0
3
false\tmetamethods_concat_len:39: attempt to index a value
false\tmetamethods_concat_len:40: attempt to perform arithmetic'

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
echo "ok: metamethods_concat_len matches"
