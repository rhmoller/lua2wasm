#!/usr/bin/env bash
set -euo pipefail

BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/milestone6.lua"
WAT="$BUILD_DIR/milestone6.wat"
WASM="$BUILD_DIR/milestone6.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features -o "$WASM" "$WAT"

EXPECTED="true
5.0
false
div by zero
true
42
false
re-raised: inner
true
1
false
two!
true
3"

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
echo "ok: milestone6 fixture matches"
