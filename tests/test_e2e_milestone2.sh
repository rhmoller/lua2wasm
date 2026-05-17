#!/usr/bin/env bash
set -euo pipefail

BIN="$1"
SRC_DIR="$2"
BUILD_DIR="$3"

FIXTURE="$SRC_DIR/tests/fixtures/milestone2.lua"
WAT="$BUILD_DIR/milestone2.wat"
WASM="$BUILD_DIR/milestone2.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features -o "$WASM" "$WAT"

EXPECTED="15
hi there
1.5
3
true
true
default
2
big
3"

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    echo "--- expected ---" >&2; echo "$EXPECTED" >&2
    echo "--- got ---"      >&2; echo "$OUT"      >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
echo "ok: milestone2 fixture matches expected output"
