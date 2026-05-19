#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/dispatch_captured_local.lua"
WAT="$BUILD_DIR/dispatch_captured_local.wat"
WASM="$BUILD_DIR/dispatch_captured_local.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features -o "$WASM" "$WAT"

EXPECTED="2"
OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
echo "ok: dispatch_captured_local matches"
