#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/string_packsize.lua"
WAT="$BUILD_DIR/string_packsize.wat"
WASM="$BUILD_DIR/string_packsize.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features --disable-custom-descriptors -o "$WASM" "$WAT"

EXPECTED=$'1
1
2
2
4
4
8
8
8
8
8
4
8
8
1
2
8
16
1
10
100
1
4
0
2
4
3
7
5
3
12
8
16
4
4
4
16
9
16
5
false\tstring_packsize:66: variable-length format
false\tstring_packsize:67: variable-length format
false\tstring_packsize:68: variable-length format
false\tstring_packsize:69: variable-length format
false\tstring_packsize:72: out of limits
false\tstring_packsize:73: out of limits
false\tstring_packsize:76: out of limits
false\tstring_packsize:77: out of limits
false\tstring_packsize:80: missing size
0
2
false\tstring_packsize:85: not power of 2
false\tnil'

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
