#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/patterns_balanced_frontier.lua"
WAT="$BUILD_DIR/patterns_balanced_frontier.wat"
WASM="$BUILD_DIR/patterns_balanced_frontier.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features --disable-custom-descriptors -o "$WASM" "$WAT"

EXPECTED=$'(bar)
(b(c)d)
[x[y]z]
nil
2\t7
1\t5
7\t11
foo
1\t3
5\t7
1\t0'

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
echo "ok: patterns_balanced_frontier matches"
