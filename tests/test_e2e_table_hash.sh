#!/usr/bin/env bash
set -euo pipefail

BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/table_hash.lua"
EXPECTED_FILE="$SRC_DIR/tests/expected/table_hash.txt"
WAT="$BUILD_DIR/table_hash.wat"
WASM="$BUILD_DIR/table_hash.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features --disable-custom-descriptors -o "$WASM" "$WAT"

EXPECTED=$(<"$EXPECTED_FILE")
OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(printf '%s\n' "$EXPECTED") <(printf '%s\n' "$OUT") >&2 || true
    exit 1
fi
echo "ok: table-hash fixture matches"
