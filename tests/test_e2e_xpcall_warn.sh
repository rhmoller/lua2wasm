#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/xpcall_warn.lua"
WAT="$BUILD_DIR/xpcall_warn.wat"
WASM="$BUILD_DIR/xpcall_warn.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features -o "$WASM" "$WAT"

EXPECTED=$'false\thandled: xpcall_warn:6: boom
true\t7
true\t1\t2\t3
false\txpcall_warn:19: from handler
1
false\th1:xpcall_warn:26: x
false\txpcall_warn:31: no level
false\tlevel 0
false\txpcall_warn:33: level 2
Lua warning: hello
Lua warning: abc
Lua warning: after
Lua warning: 123 is a number'

# stderr (warn) interleaved with stdout (print) via 2>&1.
OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM" 2>&1)"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
echo "ok: xpcall_warn matches"
