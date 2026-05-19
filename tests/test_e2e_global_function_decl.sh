#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/global_function_decl.lua"
WAT="$BUILD_DIR/global_function_decl.wat"
WASM="$BUILD_DIR/global_function_decl.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features -o "$WASM" "$WAT"

EXPECTED="hello world"
OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
echo "ok: global_function_decl matches"
