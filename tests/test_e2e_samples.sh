#!/usr/bin/env bash
# Runs the four lua.org/extras sample programs end-to-end.
# (sieve.lua needs coroutines and is excluded.)
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"

run_sample() {
    local name="$1" expected="$2"
    local lua="$SRC_DIR/tests/samples/$name.lua"
    local wat="$BUILD_DIR/sample_$name.wat"
    local wasm="$BUILD_DIR/sample_$name.wasm"
    "$BIN" "$lua" -o "$wat"
    wasm-as --all-features -o "$wasm" "$wat"
    local got
    got="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$wasm")"
    if [[ "$got" != "$expected" ]]; then
        echo "FAIL sample $name" >&2
        diff <(echo "$expected") <(echo "$got") >&2 || true
        exit 1
    fi
    echo "ok sample $name"
}

run_sample hello "Hello world, from Lua 5.5!"

run_sample account "$(cat <<'EOF'
after creation	demo	0
after deposit	demo	1000.0
after withdraw	demo	900.0
EOF
)"

run_sample globals "$(cat <<'EOF'
alpha
beta
nested
  x
  y
gamma
EOF
)"

run_sample bisect "$(cat <<'EOF'
0 c=1.5 a=1 b=2
1 c=1.25 a=1 b=1.5
2 c=1.375 a=1.25 b=1.5
3 c=1.3125 a=1.25 b=1.375
4 c=1.34375 a=1.3125 b=1.375
5 c=1.328125 a=1.3125 b=1.34375
6 c=1.3203125 a=1.3125 b=1.328125
7 c=1.32421875 a=1.3203125 b=1.328125
8 c=1.326171875 a=1.32421875 b=1.328125
9 c=1.3251953125 a=1.32421875 b=1.326171875
10 c=1.32470703125 a=1.32421875 b=1.3251953125
11 c=1.324951171875 a=1.32470703125 b=1.3251953125
12 c=1.3248291015625 a=1.32470703125 b=1.324951171875
13 c=1.3247680664063 a=1.32470703125 b=1.3248291015625
14 c=1.3247375488281 a=1.32470703125 b=1.3247680664063
15 c=1.3247222900391 a=1.32470703125 b=1.3247375488281
16 c=1.3247146606445 a=1.32470703125 b=1.3247222900391
17 c=1.3247184753418 a=1.3247146606445 b=1.3247222900391
18 c=1.3247165679932 a=1.3247146606445 b=1.3247184753418
19 c=1.3247175216675 a=1.3247165679932 b=1.3247184753418
20 c=1.3247179985046 a=1.3247175216675 b=1.3247184753418
after 20 steps, root is 1.3247179985046387 with error 9.5e-7, f=1.8e-7
EOF
)"

echo "ok: all 4 samples match"
