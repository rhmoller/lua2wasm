#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"

# --- main coverage: time/clock/date/getenv ---
FIXTURE="$SRC_DIR/tests/fixtures/os_lib.lua"
WAT="$BUILD_DIR/os_lib.wat"
WASM="$BUILD_DIR/os_lib.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features --disable-custom-descriptors -o "$WASM" "$WAT"

EXPECTED=$'number\tinteger
number\tfloat
true
2023-11-14
22:13:20
2023
%
2023\t11\t14
22\t13\t20
3\t318
boolean
hello
nil
done'

OUT="$(LUA2WASM_TEST_ENV=hello node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: os_lib output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi

# --- os.exit code propagation ---
FIXTURE2="$SRC_DIR/tests/fixtures/os_exit_42.lua"
WAT2="$BUILD_DIR/os_exit_42.wat"
WASM2="$BUILD_DIR/os_exit_42.wasm"

"$BIN" "$FIXTURE2" -o "$WAT2"
wasm-as --all-features --disable-custom-descriptors -o "$WASM2" "$WAT2"

set +e
OUT2="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM2")"
RC=$?
set -e

if [[ "$RC" != "42" ]]; then
    echo "FAIL: os.exit did not propagate code 42 (got $RC)" >&2
    exit 1
fi
if [[ "$OUT2" != "before" ]]; then
    echo "FAIL: os.exit did not stop execution before second print" >&2
    echo "got: $OUT2" >&2
    exit 1
fi

echo "ok: os shims"
