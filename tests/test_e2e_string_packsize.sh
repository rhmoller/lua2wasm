#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/string_packsize.lua"
WAT="$BUILD_DIR/string_packsize.wat"
WASM="$BUILD_DIR/string_packsize.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features -o "$WASM" "$WAT"

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
false\tnil
false\tnil
false\tnil
false\tnil
false\tnil
false\tnil
false\tnil
false\tnil
false\tnil
0
2
false\tnil
false\tnil'

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
