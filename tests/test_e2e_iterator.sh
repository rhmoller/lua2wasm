#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/iterator.lua"
WAT="$BUILD_DIR/iterator.wat"; WASM="$BUILD_DIR/iterator.wasm"
"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features -o "$WASM" "$WAT"
# Trailing print(g()) emits an empty line — bash command substitution
# strips trailing newlines from OUT, so the expected ends at "12".
EXPECTED="2
3
4
5
11
12"
OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
echo "ok: iterator matches"
