#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/patterns_gsub_repl.lua"
WAT="$BUILD_DIR/patterns_gsub_repl.wat"
WASM="$BUILD_DIR/patterns_gsub_repl.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features --disable-custom-descriptors -o "$WASM" "$WAT"

EXPECTED=$'onetwothree\t3
12XYZ\t5
A B c=3\t3
HELLO\t5
aBc\t3
xyz\t3
a:1 b:2\t2
424242\t3
false\tnil
heLLo\t2'

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
echo "ok: patterns_gsub_repl matches"
