#!/usr/bin/env bash
set -euo pipefail

BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/milestone4.lua"
WAT="$BUILD_DIR/milestone4.wat"
WASM="$BUILD_DIR/milestone4.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features --disable-custom-descriptors -o "$WASM" "$WAT"

EXPECTED="10
20
30
3
alice
30
100
200
ex
31
oslo
42
one
two
2
0
two
1
2
hello world
two
value"

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
echo "ok: milestone4 fixture matches"
