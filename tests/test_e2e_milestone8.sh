#!/usr/bin/env bash
set -euo pipefail

BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/milestone8.lua"
WAT="$BUILD_DIR/milestone8.wat"
WASM="$BUILD_DIR/milestone8.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features -o "$WASM" "$WAT"

EXPECTED="dog
dog speaks
hello
default:missing
11
22
true
false
table
nil"

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
echo "ok: milestone8 fixture matches"
