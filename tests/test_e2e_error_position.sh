#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/error_position.lua"
WAT="$BUILD_DIR/error_position.wat"
WASM="$BUILD_DIR/error_position.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features -o "$WASM" "$WAT"

EXPECTED=$'false\terror_position:4: plain
false\tno prefix
false\terror_position:12: with level 1
false\terror_position:20: two up
false\ttable
table
42
false\terror_position:36: asserted
hi
true
locked
table
table
new'

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
