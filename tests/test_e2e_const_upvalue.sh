#!/usr/bin/env bash
# A <const> local captured as an upvalue is still read-only: assigning to it
# from an inner function is a compile-time error, at any capture depth.
# Reading it, and assigning to a NON-const upvalue, must still compile.
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"

reject() { # a snippet that must NOT compile
    printf '%s\n' "$1" > "$BUILD_DIR/cu.lua"
    if "$BIN" "$BUILD_DIR/cu.lua" -o "$BUILD_DIR/cu.wat" 2>/dev/null; then
        echo "FAIL: accepted const-upvalue write: $1" >&2; exit 1
    fi
}
accept() { # a snippet that MUST compile and run to the expected stdout
    printf '%s\n' "$1" > "$BUILD_DIR/cu.lua"
    if ! "$BIN" "$BUILD_DIR/cu.lua" -o "$BUILD_DIR/cu.wasm" 2>/dev/null; then
        echo "FAIL: rejected valid program: $1" >&2; exit 1
    fi
    local out; out="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$BUILD_DIR/cu.wasm")"
    if [[ "$out" != "$2" ]]; then
        echo "FAIL: $1 -> [$out], expected [$2]" >&2; exit 1
    fi
}

reject 'local x <const> = 1; local function f() x = 2 end'
reject 'local x <const> = 1; local function f() local function g() x = 2 end end'
reject 'local x <const> = 1; local function f() x, x = 2, 3 end'
accept 'local x <const> = 1; local function f() return x end; print(f())' '1'
accept 'local y = 1; local function f() y = 2 end; f(); print(y)' '2'
