#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/string_escapes.lua"
WAT="$BUILD_DIR/string_escapes.wat"
WASM="$BUILD_DIR/string_escapes.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features --disable-custom-descriptors -o "$WASM" "$WAT"

EXPECTED=$'3
10
9
7
8
12
11
\\quote\\
"inner"
inner
1\t0
65
255
255
65
65
1
255
abcdef
abcd
2
3
4
Hi!
first
second
3'

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
echo "ok: string_escapes matches"
