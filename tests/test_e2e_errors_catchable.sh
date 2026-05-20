#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/errors_catchable.lua"
WAT="$BUILD_DIR/errors_catchable.wat"
WASM="$BUILD_DIR/errors_catchable.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features --disable-custom-descriptors -o "$WASM" "$WAT"

# Every builtin error path must produce a non-nil (string) error value, so
# pcall yields `false  string`. Before the throw-payload fix these threw nil
# and printed `false  nil`, making the error uncatchable.
EXPECTED=$'false\tstring
false\tstring
false\tstring
false\tstring
false\tstring
false\tstring
false\tstring
false\tstring
false\tstring'

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
echo "ok: builtin errors are catchable strings"
