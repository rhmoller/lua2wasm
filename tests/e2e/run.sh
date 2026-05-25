#!/usr/bin/env bash
# Generic end-to-end runner for one manifest row: compile a fixture straight to
# a binary module (lua2wasm assembles it internally), run it under Node, and
# compare stdout against the golden file tests/e2e/expected/<name>.txt.
#
#   run.sh <lua2wasm> <src-dir> <build-dir> <name> <fixture-rel-path> [golden-name] [extra-flags...]
#
# <name> identifies this run (names the scratch .wasm). [golden-name] defaults
# to <name>; pass it to reuse another case's golden. Any args after it are
# extra compiler flags. The fallback pass runs each fixture as o0_<name> with
# `-O0` against the default <name> golden, since the boxed fallback must
# produce output identical to the (specialized) default.
#
# Goldens are captured from the current pipeline; regenerate with
# tests/e2e/regen.sh after an intended output change.
set -uo pipefail
BIN="$1"; SRC_DIR="$2"; BUILD_DIR="$3"; NAME="$4"; FIXTURE="$5"; GOLDEN_NAME="${6:-$4}"
EXTRA=("${@:7}")  # args 7.. are extra compiler flags (e.g. -O0)

WASM="$BUILD_DIR/e2e_$NAME.wasm"
GOLDEN="$SRC_DIR/tests/e2e/expected/$GOLDEN_NAME.txt"

if ! "$BIN" "$SRC_DIR/$FIXTURE" ${EXTRA[@]+"${EXTRA[@]}"} -o "$WASM"; then
    echo "FAIL: $NAME compile failed" >&2; exit 1
fi

# $(...) strips trailing newlines on both sides, so a golden file's final
# newline never causes a spurious mismatch.
OUT="$(node --experimental-wasm-exnref "$SRC_DIR/runtime/host.mjs" "$WASM")"
EXP="$(cat "$GOLDEN")"
if [[ "$OUT" != "$EXP" ]]; then
    echo "FAIL: $NAME output mismatch" >&2
    diff <(printf '%s\n' "$EXP") <(printf '%s\n' "$OUT") >&2 || true
    exit 1
fi
