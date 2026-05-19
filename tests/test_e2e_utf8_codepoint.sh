#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/utf8_codepoint.lua"
WAT="$BUILD_DIR/utf8_codepoint.wat"
WASM="$BUILD_DIR/utf8_codepoint.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features --disable-custom-descriptors -o "$WASM" "$WAT"

EXPECTED=$'65
65
66
65\t66\t67
104\t101\t108\t108\t111
233
9731
128512
97\t233\t9731\t128512
hello
false\tutf8_codepoint:25: invalid UTF-8 code
false\tutf8_codepoint:28: invalid UTF-8 code
0'

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
echo "ok: utf8_codepoint matches"
