#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/io_read_full.lua"
WAT="$BUILD_DIR/io_read_full.wat"
WASM="$BUILD_DIR/io_read_full.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
"$BUILD_DIR/wat2wasm" -o "$WASM" "$WAT"

EXPECTED=$'first
second
[third
]
42\tfloat
[]
ABCDE
[extra
]
[tail]
[]
nil
nil
nil'

OUT="$(printf 'first\nsecond\nthird\n42 3.14\nABCDEextra\ntail' | node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
echo "ok: io_read_full matches"
