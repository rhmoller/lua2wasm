#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/utf8_offset.lua"
WAT="$BUILD_DIR/utf8_offset.wat"
WASM="$BUILD_DIR/utf8_offset.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features --disable-custom-descriptors -o "$WASM" "$WAT"

EXPECTED=$'11
1
2
4
7
11
12
nil
11
7
4
2
1
nil
1
2
4
7
11
2
4
2
12
nil
false\tinvalid UTF-8 code'

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
echo "ok: utf8_offset matches"
