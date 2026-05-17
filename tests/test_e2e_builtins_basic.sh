#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/builtins_basic.lua"
WAT="$BUILD_DIR/builtins_basic.wat"
WASM="$BUILD_DIR/builtins_basic.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features -o "$WASM" "$WAT"

EXPECTED="Lua 5.5
42
hello, world
abc
false
boom"

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
echo "ok: builtins_basic matches"
