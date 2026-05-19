#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/patterns_captures.lua"
WAT="$BUILD_DIR/patterns_captures.wat"
WASM="$BUILD_DIR/patterns_captures.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features --disable-custom-descriptors -o "$WASM" "$WAT"

EXPECTED=$'1\t11\thello\tworld
1\t3\ta\tb\tc
1\t1\t1
3\t5\t3\t123\t6
4\t8\t(bar)
1\t2\taA\ta\tA
1\t3\ta
1\t6\txyz
nil
1\t5\thello
2\t2\t1
1\t1\t
2\t2
nil'

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
echo "ok: patterns_captures matches"
