#!/usr/bin/env bash
# Covers the $tab_bootstrap_set path: under --force-tree-shake a table-free program's
# _G / library tables are installed with the append-only bootstrap helper, which
# lets DCE drop the whole table write path. Checks both that it still runs
# correctly and that dropping the write path actually shrinks the module.
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIX="$SRC_DIR/tests/fixtures/tree_shake_bootstrap.lua"
WASM="$BUILD_DIR/tree_shake_bootstrap.wasm"

# 1. Behaviour — the bootstrap-built tables must read back correctly.
"$BIN" "$FIX" --force-tree-shake -o "$WASM"
OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
EXPECTED=$'7\nABC\txxx\nfunction\t42\t3'
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(printf '%s\n' "$EXPECTED") <(printf '%s\n' "$OUT") >&2 || true
    exit 1
fi

# 2. Size — the same program plus one table write keeps the write path live, so
#    it must assemble larger. This proves the table-free build actually drops
#    the write path rather than just renaming the bootstrap call.
VAR="$BUILD_DIR/tree_shake_bootstrap_write.lua"
{ cat "$FIX"; printf 'local _w = {}\n_w[1] = 1\nprint(_w[1])\n'; } >"$VAR"
WASM_W="$BUILD_DIR/tree_shake_bootstrap_write.wasm"
"$BIN" "$VAR" --force-tree-shake -o "$WASM_W"
FREE=$(wc -c <"$WASM"); WRITE=$(wc -c <"$WASM_W")
if [[ "$FREE" -ge "$WRITE" ]]; then
    echo "FAIL: table-free build ($FREE B) not smaller than table-writing build ($WRITE B)" >&2
    exit 1
fi
echo "ok: bootstrap_set output correct; dropping the write path saves $((WRITE - FREE)) bytes"
