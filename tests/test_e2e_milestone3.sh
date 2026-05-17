#!/usr/bin/env bash
set -euo pipefail

BIN="$1"
SRC_DIR="$2"
BUILD_DIR="$3"

FIXTURE="$SRC_DIR/tests/fixtures/milestone3.lua"
WAT="$BUILD_DIR/milestone3.wat"
WASM="$BUILD_DIR/milestone3.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features -o "$WASM" "$WAT"

EXPECTED="720
1
2
3
1
4
42
101
102"

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
echo "ok: milestone3 fixture matches"
