#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/string_format.lua"
WAT="$BUILD_DIR/string_format.wat"; WASM="$BUILD_DIR/string_format.wasm"
"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features -o "$WASM" "$WAT"

EXPECTED="hi
42
-7
a/b
[1, 2, 3]
1.5
3.1415926535897931
3.14
1.2e+4
ff
100%
n=7  s=hi  pi=3.14"
OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
echo "ok: string_format matches"
