#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
DIR="$SRC_DIR/tests/fixtures/milestone25"
WAT="$BUILD_DIR/milestone25.wat"
WASM="$BUILD_DIR/milestone25.wasm"

"$BIN" "$DIR/main.lua" -m "$DIR/util.lua" -m "$DIR/wrap.lua" -o "$WAT"
"$BUILD_DIR/wat2wasm" -o "$WASM" "$WAT"

EXPECTED=$'OK!
abab
true
=== HELLO ===!
xyxy
false\tmain:50: module \'nope\' not loaded
table
table
table
true'

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
