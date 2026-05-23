#!/usr/bin/env bash
# A -m module (and the entry) may begin with a shebang / first-line '#'
# comment, which Lua skips in any loaded chunk. Regression: modules are
# wrapped + concatenated before lexing, so only the first source's shebang
# was stripped — a module's shebang lexed as `#` then `!` => lex error.
set -euo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"
DIR="$SRC_DIR/tests/fixtures/module_shebang"
WAT="$BUILD_DIR/module_shebang.wat"
WASM="$BUILD_DIR/module_shebang.wasm"

"$BIN" "$DIR/main.lua" -m "$DIR/greet.lua" -o "$WAT"
"$BUILD_DIR/wat2wasm" -o "$WASM" "$WAT"

EXPECTED=$'hello, world
hello, lua2wasm'
OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
if [[ "$OUT" != "$EXPECTED" ]]; then
    echo "FAIL: output mismatch" >&2
    diff <(echo "$EXPECTED") <(echo "$OUT") >&2 || true
    exit 1
fi
echo "ok: shebang in entry + module"
