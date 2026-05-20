#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"

FIXTURE="$SRC_DIR/tests/fixtures/io_file.lua"
WAT="$BUILD_DIR/io_file.wat"
WASM="$BUILD_DIR/io_file.wasm"
TMPFILE="$BUILD_DIR/io_file_data.txt"

rm -f "$TMPFILE" "$TMPFILE.renamed"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features --disable-custom-descriptors -o "$WASM" "$WAT"

EXPECTED=$'line1\n12\nline1\n0\nline1\n6\nL:line1\nL:line2\nL:line3\nfile\nclosed file\nnil\nnil\ttrue\nnil\ndone'

OUT="$(LUA2WASM_TEST_FILE="$TMPFILE" \
    node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"

rm -f "$TMPFILE" "$TMPFILE.renamed"

if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: io_file output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi

echo "ok: io filesystem"
