#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/patterns_find_basic.lua"
WAT="$BUILD_DIR/patterns_find_basic.wat"
WASM="$BUILD_DIR/patterns_find_basic.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features --disable-custom-descriptors -o "$WASM" "$WAT"

EXPECTED=$'2\t4
nil
1\t1
1\t3
nil
1\t1
3\t3
1\t3
nil
3\t3
3\t4
1\t2
2\t2
4\t4
4\t4
1\t3
1\t3
1\t2
1\t1
1\t0
1\t4
5\t5
nil
6\t8
1\t4'

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
echo "ok: patterns_find_basic matches"
