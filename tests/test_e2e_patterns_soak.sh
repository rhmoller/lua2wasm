#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/patterns_soak.lua"
WAT="$BUILD_DIR/patterns_soak.wat"
WASM="$BUILD_DIR/patterns_soak.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features --disable-custom-descriptors -o "$WASM" "$WAT"

EXPECTED=$'Hello
123
2
F
oo
a1b2c3
0
,
2
hello!@#
1\t3
1\t2
e
-1
abc
**!!%%
aaa
ab
b
a
color
colour
he
lo
hello
nil
hello\tworld

nil
n\to
foo\t4
(b(c)d)
7\t11
a1,b2,c3
heLLo\t2
<foo><bar>\t2
aaa\t3
bac\t1
hi earth\t2
4\t4
2\t2
nil'

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
echo "ok: patterns_soak matches"
