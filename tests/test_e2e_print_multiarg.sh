#!/usr/bin/env bash
# Regression test for print(...) accepting multiple args.
set -euo pipefail

BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/print_multiarg.lua"
EXPECTED_FILE="$SRC_DIR/tests/expected/print_multiarg.txt"
WAT="$BUILD_DIR/print_multiarg.wat"
WASM="$BUILD_DIR/print_multiarg.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features --disable-custom-descriptors -o "$WASM" "$WAT"

EXPECTED=$(<"$EXPECTED_FILE")
OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(printf '%s\n' "$EXPECTED") <(printf '%s\n' "$OUT") >&2 || true
    exit 1
fi
echo "ok: print_multiarg fixture matches"
