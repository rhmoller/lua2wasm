#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/string_format_full.lua"
WAT="$BUILD_DIR/string_format_full.wat"
WASM="$BUILD_DIR/string_format_full.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features -o "$WASM" "$WAT"

EXPECTED='[        hi]
[hi        ]
[   42]
[42   ]
[00042]
[-0042]
+5
-5
 5
-5
0xff
0XFF
010
hel
[       hel]
00042

5
7
10
42
ff
FF
A
Hi!
1.234500E+04
3.140000
1.5
"hello"
"a\nb"
"it'"'"'s \"x\""
25% off!
ab   |00007|   3.142'

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
echo "ok: string_format_full matches"
