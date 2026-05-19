#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/patterns_gsub_string.lua"
WAT="$BUILD_DIR/patterns_gsub_string.wat"
WASM="$BUILD_DIR/patterns_gsub_string.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features --disable-custom-descriptors -o "$WASM" "$WAT"

EXPECTED=$'hell0 w0rld\t2
hell0 world\t1
XXX\t3
hi N, bye N\t2
[foo] [bar] [baz]\t3
XhelloY\t1
XhelloY\t1
1:a,2:b,\t2
%%%%\t4
abc\t0
-a-b-c-\t4
-\t1
yxxx\t1
XnYXnY\t2'

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
echo "ok: patterns_gsub_string matches"
