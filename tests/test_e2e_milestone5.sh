#!/usr/bin/env bash
set -euo pipefail

BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/milestone5.lua"
WAT="$BUILD_DIR/milestone5.wat"
WASM="$BUILD_DIR/milestone5.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features --disable-custom-descriptors -o "$WASM" "$WAT"

EXPECTED="55
10
8
6
4
2
1
2
3
3
1
1
2
4
3
9
4
16
1
2
3
1
2
2
20"

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
echo "ok: milestone5 fixture matches"
