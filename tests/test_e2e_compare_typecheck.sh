#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/compare_typecheck.lua"
WAT="$BUILD_DIR/compare_typecheck.wat"
WASM="$BUILD_DIR/compare_typecheck.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features --disable-custom-descriptors -o "$WASM" "$WAT"

EXPECTED=$'true
false
true
true
true
true
true
false
true
true
true
true
false
false
false
false\tnil
false\tnil
false\tnil
false\tnil
false\tnil
false\tnil
false\tnil'

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
echo "ok: compare_typecheck matches"
