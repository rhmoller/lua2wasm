#!/usr/bin/env bash
# Covers default (flag-free) tree-shaking gated on an escape analysis: a program
# whose static set of named builtins/globals is complete ("globally closed" — no
# _G/_ENV mention, no load/require) drops every builtin it never names, with no
# behaviour change. A program that can reach a builtin dynamically (here via
# _G.print) is NOT closed, so the full runtime is kept and the lookup still
# works — the soundness property that lets this be the default.
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
HOST="$SRC_DIR/runtime/host.mjs"

# A builtin the closed program below never names; its closure global must be
# gone by default once tree-shaking is automatic.
UNUSED='\$g_builtin_math_sin'

# 1. Closed program: compiles, runs, and drops the unused builtin by default.
CLOSED="$BUILD_DIR/dts_closed.lua"
printf 'print("hi")\n' >"$CLOSED"
CLOSED_WAT="$BUILD_DIR/dts_closed.wat"
CLOSED_WASM="$BUILD_DIR/dts_closed.wasm"
"$BIN" "$CLOSED" -o "$CLOSED_WAT"
if grep -q "$UNUSED" "$CLOSED_WAT"; then
    echo "FAIL: closed program kept unused builtin (math.sin) by default" >&2
    exit 1
fi
"$BIN" "$CLOSED" -o "$CLOSED_WASM"
OUT="$(node --experimental-wasm-exnref "$HOST" "$CLOSED_WASM")"
[[ "$OUT" == "hi" ]] || { echo "FAIL: closed output: want hi, got: $OUT" >&2; exit 1; }

# 2. Not-closed program: _G makes the static set incomplete, so the runtime is
#    kept and _G.print still resolves (this is the regression --tree-shake had).
OPEN="$BUILD_DIR/dts_open.lua"
printf 'local p = _G.print\np("hi")\n' >"$OPEN"
OPEN_WAT="$BUILD_DIR/dts_open.wat"
OPEN_WASM="$BUILD_DIR/dts_open.wasm"
"$BIN" "$OPEN" -o "$OPEN_WAT"
if ! grep -q "$UNUSED" "$OPEN_WAT"; then
    echo "FAIL: _G program tree-shook anyway (unsound); math.sin was dropped" >&2
    exit 1
fi
"$BIN" "$OPEN" -o "$OPEN_WASM"
OPEN_OUT="$(node --experimental-wasm-exnref "$HOST" "$OPEN_WASM")"
[[ "$OPEN_OUT" == "hi" ]] || { echo "FAIL: _G.print output: want hi, got: $OPEN_OUT" >&2; exit 1; }

# 3. Library-only access (math.sqrt) must NOT drag in the string library: the
#    index base is a known library, never a string, so the string metatable
#    can't apply. A string-only builtin must be gone.
LIBONLY="$BUILD_DIR/dts_libonly.lua"
printf 'print(math.sqrt(4))\n' >"$LIBONLY"
LIBONLY_WAT="$BUILD_DIR/dts_libonly.wat"
LIBONLY_WASM="$BUILD_DIR/dts_libonly.wasm"
# Check the codegen-conditional closure *global* ($g_builtin_*), not the func
# body — the prelude defines every builtin body unconditionally (DCE drops the
# unused ones later); only the global + install are tree-shaken in codegen.
"$BIN" "$LIBONLY" -o "$LIBONLY_WAT"
if grep -q 'global \$g_builtin_string_format' "$LIBONLY_WAT"; then
    echo "FAIL: math.sqrt program kept the string library (over-conservative)" >&2
    exit 1
fi
"$BIN" "$LIBONLY" -o "$LIBONLY_WASM"
LO_OUT="$(node --experimental-wasm-exnref "$HOST" "$LIBONLY_WASM")"
[[ "$LO_OUT" == "2.0" ]] || { echo "FAIL: math.sqrt output: want 2.0, got: $LO_OUT" >&2; exit 1; }

# A string method, by contrast, must keep the string library live.
SMETH="$BUILD_DIR/dts_smeth.lua"
printf 'print(("ab"):upper())\n' >"$SMETH"
SMETH_WAT="$BUILD_DIR/dts_smeth.wat"
"$BIN" "$SMETH" -o "$SMETH_WAT"
if ! grep -q 'global \$g_builtin_string_upper' "$SMETH_WAT"; then
    echo "FAIL: string method dropped the string library (unsound)" >&2
    exit 1
fi

# 4. Size: dropping the runtime the closed program can't reach makes it smaller.
C_SZ=$(wc -c <"$CLOSED_WASM"); O_SZ=$(wc -c <"$OPEN_WASM")
if [[ "$C_SZ" -ge "$O_SZ" ]]; then
    echo "FAIL: closed build ($C_SZ B) not smaller than _G build ($O_SZ B)" >&2
    exit 1
fi
echo "ok: default tree-shake fires when closed ($C_SZ B), keeps runtime for _G ($O_SZ B)"
