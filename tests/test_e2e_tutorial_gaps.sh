#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/tutorial_gaps.lua"
WAT="$BUILD_DIR/tutorial_gaps.wat"; WASM="$BUILD_DIR/tutorial_gaps.wasm"
"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features --disable-custom-descriptors -o "$WASM" "$WAT"
EXPECTED="true
0.0
1.0
1.000000
1.000000
1.000000
hello
value
true
 Double brackets
true
false
stored
nil"
OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
echo "ok: tutorial_gaps matches"
