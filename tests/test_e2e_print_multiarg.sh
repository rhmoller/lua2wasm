#!/usr/bin/env bash
# Regression test for print(...) accepting multiple args.
# Real Lua joins args with TAB and ends with a single newline.
set -euo pipefail

BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/print_multiarg.lua"
WAT="$BUILD_DIR/print_multiarg.wat"
WASM="$BUILD_DIR/print_multiarg.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features -o "$WASM" "$WAT"

# Build the expected output with literal tabs.
EXPECTED=$'1\t2\t3\na\tb\n\nsolo\nnil\ttrue\t42\tx'

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(printf '%s\n' "$EXPECTED") <(printf '%s\n' "$OUT") >&2 || true
    exit 1
fi
echo "ok: print_multiarg fixture matches"
