#!/usr/bin/env bash
set -euo pipefail

BIN="$1"
SRC_DIR="$2"
BUILD_DIR="$3"

FIXTURE="$SRC_DIR/tests/fixtures/milestone3b.lua"
WAT="$BUILD_DIR/milestone3b.wat"
WASM="$BUILD_DIR/milestone3b.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features --disable-custom-descriptors -o "$WASM" "$WAT"

EXPECTED="10
20
nil
2
1
100
10
20
done
12"

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
echo "ok: milestone3b fixture matches"
