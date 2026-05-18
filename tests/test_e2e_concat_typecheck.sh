#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/concat_typecheck.lua"
WAT="$BUILD_DIR/concat_typecheck.wat"
WASM="$BUILD_DIR/concat_typecheck.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features -o "$WASM" "$WAT"

EXPECTED=$'ab
a1
1a
12
1.5x
false\tnil
false\tnil
false\tnil
false\tnil
false\tnil
false\tnil
nil
true\tnil\tfalse
table\tnil'

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
echo "ok: concat_typecheck matches"
