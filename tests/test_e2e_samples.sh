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
    "$BUILD_DIR/wat2wasm" -o "$wasm" "$wat"
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
13 c=1.32476806640625 a=1.32470703125 b=1.3248291015625
14 c=1.324737548828125 a=1.32470703125 b=1.32476806640625
15 c=1.3247222900390625 a=1.32470703125 b=1.324737548828125
16 c=1.3247146606445312 a=1.32470703125 b=1.3247222900390625
17 c=1.3247184753417969 a=1.3247146606445312 b=1.3247222900390625
18 c=1.3247165679931641 a=1.3247146606445312 b=1.3247184753417969
19 c=1.3247175216674805 a=1.3247165679931641 b=1.3247184753417969
20 c=1.3247179985046387 a=1.3247175216674805 b=1.3247184753417969
after 20 steps, root is 1.3247179985046387 with error 9.5e-07, f=1.8e-07
EOF
)"

echo "ok: all 4 samples match"
