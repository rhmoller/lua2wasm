#!/usr/bin/env bash
# Covers the $stdlib_init skip gate: a program that observes no runtime state
# (no globals/builtins/operators/indexing/calls/for-loops) never needs the
# library tables, metamethod-key globals, or _G that $stdlib_init builds, so
# codegen drops the `(call $stdlib_init)` from $main. DCE then cascade-removes
# $stdlib_init itself and everything it solely pinned. A program that uses any
# runtime feature must keep the call. Checks WAT shape, behaviour, and size.
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FREE_FIX="$SRC_DIR/tests/fixtures/runtime_free.lua"
FREE_WAT="$BUILD_DIR/runtime_free.wat"
FREE_WASM="$BUILD_DIR/runtime_free.wasm"

# 1. Gate fires: the runtime-free program must not call $stdlib_init.
"$BIN" "$FREE_FIX" -o "$FREE_WAT"
if grep -q '(call \$stdlib_init)' "$FREE_WAT"; then
    echo "FAIL: runtime-free program still calls \$stdlib_init" >&2
    exit 1
fi

# 2. Behaviour: it still instantiates and runs cleanly (returns 42, discarded;
#    no output). A null stdlib global being read would trap here.
"$BIN" "$FREE_FIX" -o "$FREE_WASM"
OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$FREE_WASM")"
if [[ -n "$OUT" ]]; then
    echo "FAIL: expected no output, got: $OUT" >&2
    exit 1
fi

# 3. Gate stays off when runtime is used: the same local computation but with a
#    print() makes it observe the runtime, so the call returns, output is
#    correct, and the module is larger (the runtime is back).
USE_LUA="$BUILD_DIR/runtime_used.lua"
printf 'local x = 10\nlocal y = x\nif y then y = x end\nprint(y)\n' >"$USE_LUA"
USE_WAT="$BUILD_DIR/runtime_used.wat"
USE_WASM="$BUILD_DIR/runtime_used.wasm"
"$BIN" "$USE_LUA" -o "$USE_WAT"
if ! grep -q '(call \$stdlib_init)' "$USE_WAT"; then
    echo "FAIL: runtime-using program dropped \$stdlib_init" >&2
    exit 1
fi
"$BIN" "$USE_LUA" -o "$USE_WASM"
USE_OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$USE_WASM")"
if [[ "$USE_OUT" != "10" ]]; then
    echo "FAIL: runtime-using output mismatch: want 10, got: $USE_OUT" >&2
    exit 1
fi

FREE_SZ=$(wc -c <"$FREE_WASM"); USE_SZ=$(wc -c <"$USE_WASM")
if [[ "$FREE_SZ" -ge "$USE_SZ" ]]; then
    echo "FAIL: runtime-free build ($FREE_SZ B) not smaller than runtime-using ($USE_SZ B)" >&2
    exit 1
fi
echo "ok: skip gate drops \$stdlib_init; runtime-free build saves $((USE_SZ - FREE_SZ)) bytes"
