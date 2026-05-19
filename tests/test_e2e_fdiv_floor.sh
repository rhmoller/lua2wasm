#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/fdiv_floor.lua"
WAT="$BUILD_DIR/fdiv_floor.wat"
WASM="$BUILD_DIR/fdiv_floor.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features --disable-custom-descriptors -o "$WASM" "$WAT"

EXPECTED="2
-3
-3
2
2
-2
2
-3
0
3.0
-3.0
3.0
-4.0
7
-7
7
-7
3.0
3.0"

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
echo "ok: fdiv_floor matches"
