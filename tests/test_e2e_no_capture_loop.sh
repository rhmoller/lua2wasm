#!/usr/bin/env bash
# Verifies the unboxing optimisation: a function that captures no locals
# must compile without any $Box reads or writes.
set -euo pipefail

BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/no_capture_loop.lua"
WAT="$BUILD_DIR/no_capture_loop.wat"
WASM="$BUILD_DIR/no_capture_loop.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features -o "$WASM" "$WAT"

# Output check first.
OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "500500" ]]; then
    echo "FAIL: expected 500500, got '$OUT'" >&2
    exit 1
fi

# Box-free check: the only $Box references allowed are in the embedded
# prelude (helpers like $tab_find that work on any value, etc.). The
# user-code section starts at "(func $main".
USER_BOX_OPS=$(awk '/\(func \$main/{in_main=1} in_main && (/struct\.new \$Box/ || /struct\.get \$Box \$v/ || /struct\.set \$Box \$v/){count++} END{print count+0}' "$WAT")
if [[ "$USER_BOX_OPS" -ne 0 ]]; then
    echo "FAIL: expected zero \$Box ops in \$main, found $USER_BOX_OPS" >&2
    grep -n -E 'struct\.(new|get|set) \$Box' "$WAT" | tail -20 >&2
    exit 1
fi

echo "ok: tight loop runs unboxed (no \$Box ops in \$main)"
