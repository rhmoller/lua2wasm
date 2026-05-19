#!/usr/bin/env bash
# E2E test for varargs (`...`) and `select`.
set -euo pipefail

BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/varargs.lua"
EXPECTED_FILE="$SRC_DIR/tests/expected/varargs.txt"
WAT="$BUILD_DIR/varargs.wat"
WASM="$BUILD_DIR/varargs.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features --disable-custom-descriptors -o "$WASM" "$WAT"

EXPECTED=$(<"$EXPECTED_FILE")

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(printf '%s\n' "$EXPECTED") <(printf '%s\n' "$OUT") >&2 || true
    exit 1
fi
echo "ok: varargs fixture matches"
