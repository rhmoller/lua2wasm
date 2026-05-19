#!/usr/bin/env bash
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
FIXTURE="$SRC_DIR/tests/fixtures/string_unpack_overflow.lua"
WAT="$BUILD_DIR/string_unpack_overflow.wat"
WASM="$BUILD_DIR/string_unpack_overflow.wasm"

"$BIN" "$FIXTURE" -o "$WAT"
wasm-as --all-features --disable-custom-descriptors -o "$WASM" "$WAT"

EXPECTED=$'false\tstring_unpack_overflow:5: data does not fit
false\tstring_unpack_overflow:6: data does not fit
false\tstring_unpack_overflow:7: data does not fit
false\tstring_unpack_overflow:11: data does not fit
false\tstring_unpack_overflow:13: data does not fit
false\tstring_unpack_overflow:15: data does not fit
578437695752307201\t10
-1\t10
1\t10
-1\t17'

OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
echo "ok: string_unpack_overflow matches"
