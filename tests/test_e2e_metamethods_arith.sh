#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/metamethods_arith.lua"
WAT="$BUILD_DIR/metamethods_arith.wat"
WASM="$BUILD_DIR/metamethods_arith.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features --disable-custom-descriptors -o "$WASM" "$WAT"

EXPECTED=$'add\tadd
sub\tsub
mul\tmul
div\tdiv
mod\tmod
pow\tpow
idiv\tidiv
unm
add
5
2
2
true
false\tnil
false\tnil'

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
echo "ok: metamethods_arith matches"
