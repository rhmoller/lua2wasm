#!/usr/bin/env bash
# Compile-time checks that reference Lua 5.5 makes, each case taken from
# `load(src)` under lua5.5: a snippet either compiles ("ok") or fails with
# "line N: <message>", reference Lua's own message and line.
#
#   - strict globals: inside the scope of a global declaration, a free name
#     must be declared ("variable 'y' not declared"); `global *` restores
#     free access and `global<const> *` / `<const>` make globals read-only
#   - goto may not jump into the scope of a local or global declaration;
#     a label that ends its block is outside the block's declarations
set -uo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
WORK="$BUILD_DIR/compile_checks"
mkdir -p "$WORK"

fail=0
check() { # name expect source
    local name="$1" expect="$2" src="$3"
    printf '%b\n' "$src" > "$WORK/case.lua"
    local err
    if err="$("$BIN" "$WORK/case.lua" -o "$WORK/case.wat" 2>&1)"; then
        if [[ "$expect" != ok ]]; then
            echo "FAIL $name: compiled, expected '$expect'" >&2; fail=1
        fi
    elif [[ "$expect" == ok ]]; then
        echo "FAIL $name: expected to compile, got: $err" >&2; fail=1
    elif [[ "$err" != *"$expect"* ]]; then
        echo "FAIL $name: expected '$expect', got: $err" >&2; fail=1
    fi
}

# --- strict globals ---------------------------------------------------------
check "undeclared read"            "line 2: variable 'print' not declared" 'global x\nprint(1)'
check "undeclared write"           "line 2: variable 'y' not declared"     'global x\ny = 1'
check "declared ok"                ok                                      'global x, print\nx = 1 print(x)'
check "block scoped"               ok                                      'do global x end\ny = 1 print(y)'
check "nested function"            "line 2: variable 'y' not declared"     'global x\nlocal function f() y = 1 end'
check "upvalue of declaration"     "line 1: variable 'r' not declared"     'local function f() global q; return function() return r end end'
check "collective restores"        ok                                      'global x\nglobal *\ny = 1'
check "const collective write"     "line 2: attempt to assign to const variable 'y'" 'global<const> *\ny = 1'
check "const collective read"      ok                                      'global<const> *\nprint(y)'
check "const collective + named"   "line 4: attempt to assign to const variable 'Y'" 'global<const> *\nglobal X\nX = 1\nY = 1'
check "named const"                "line 2: attempt to assign to const variable 'X'" 'global X <const>\nX = 1'
check "prefix const"               "line 2: attempt to assign to const variable 'Z'" 'global <const> X, Z\nZ = 1'
check "const in nested function"   "line 2: attempt to assign to const variable 'z'" 'global<const> *\nlocal function f() z = 1 end'
check "function statement"         "line 2: variable 'g' not declared"     'global x\nfunction g() end'
check "function statement const"   "line 2: attempt to assign to const variable 'f'" 'global<const> *\nfunction f() end'
check "global function ok"         ok                                      'global x\nglobal function g() return g end'
check "global function const ok"   ok                                      'global<const> *\nglobal function f() end'
check "field function"             "line 2: variable 'T' not declared"     'global x\nfunction T.m() end'
check "local function ok"          ok                                      'global x\nlocal function h() end'
check "_ENV is never free"         ok                                      'global x\n_ENV.y = 1\nlocal e = _ENV'
check "local shadows"              ok                                      'global x\nlocal y = 1\ny = 2'
check "const shadowed by local"    ok                                      'global<const> X\nlocal X = 1\nX = 2'
check "field write ok"             ok                                      'global<const> *\nt.x = 1'
check "global shadows local"       ok                                      'local z = 1\ndo global z; z = 7 end'
check "const local names itself"   "line 2: attempt to assign to const variable 'k'" 'local k <const> = 1\nk = 2'
check "const upvalue names itself" "line 2: attempt to assign to const variable 'k'" 'local k <const> = 1\nlocal function f() k = 2 end'
check "global close prefix"        "line 1: global variables cannot be to-be-closed" 'global <close> x'
check "global close per name"      "line 1: global variables cannot be to-be-closed" 'global x <close>'
check "global close collective"    "line 1: global variables cannot be to-be-closed" 'global <close> *'

# --- goto into a scope ------------------------------------------------------
check "goto into local"            "line 1: <goto skip> at line 1 jumps into the scope of 'x'" 'do goto skip; local x = 1; ::skip:: print(1) end'
check "goto into local, lines"     "line 5: <goto skip> at line 2 jumps into the scope of 'x'" 'do\n  goto skip\n  local x = 1\n  ::skip::\n  print("ran")\nend'
check "goto to block end ok"       ok                                      'do goto e; local x = 1; ::e:: end'
check "goto end with semis ok"     ok                                      'do goto e; local x = 1; ::e:: ; ::f:: end'
check "goto continue ok"           ok                                      'for i = 1, 2 do if i then goto c end local y = i ::c:: end'
check "goto into repeat scope"     "line 1: <goto c> at line 1 jumps into the scope of 'y'" 'repeat goto c; local y = 1 ::c:: until y'
check "goto into global"           "line 1: <goto s> at line 1 jumps into the scope of 'X'" 'do goto s; global X; ::s:: X = 1 end'
check "goto into collective"       "line 1: <goto s> at line 1 jumps into the scope of '*'" 'do goto s; global *; ::s:: y = 1 end'
check "goto out of nested block"   "line 1: <goto L> at line 1 jumps into the scope of 'a'" 'do do goto L end local a ::L:: print(a) end'
check "goto out of loop body"      "line 1: <goto L> at line 1 jumps into the scope of 'a'" 'do for i = 1, 2 do goto L end local a ::L:: print(a) end'
check "goto backward ok"           ok                                      'do local a ::L:: a = 1 goto L end'
check "goto into local function"   "line 1: <goto s> at line 1 jumps into the scope of 'f'" 'do goto s; local function f() end ::s:: f() end'
check "goto from if arm"           "line 1: <goto s> at line 1 jumps into the scope of 'q'" 'if x then goto s else end local q ::s:: print(q)'
check "label last before else ok"  ok                                      'if x then goto s; local q ::s:: else end'
check "goto past nested function"  ok                                      'goto L\nlocal function f() local a ::L:: end\n::L::'

if [[ $fail -ne 0 ]]; then exit 1; fi
echo "compile checks: ok"
