#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/metamethods_ni_ts_mt.lua"
WAT="$BUILD_DIR/metamethods_ni_ts_mt.wat"
WASM="$BUILD_DIR/metamethods_ni_ts_mt.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features -o "$WASM" "$WAT"

EXPECTED=$'<v=42>
<v=42>
<v=42>
"<v=42>"
false\tnil
nil\tnil\t99
foo=1; bar=2
yes
x\ty
nil
locked
false\tnil
false\tnil
table
7'

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
echo "ok: metamethods_ni_ts_mt matches"
