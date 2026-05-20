#!/usr/bin/env bash
# Regenerate every e2e golden in tests/e2e/expected/ from the current
# compiler + runtime. Run this after an *intended* output change, then review
# the diff before committing.
#
#   tests/e2e/regen.sh [lua2wasm] [src-dir] [build-dir]
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BIN="${1:-$ROOT/build/lua2wasm}"
SRC_DIR="${2:-$ROOT}"
BUILD_DIR="${3:-$ROOT/build}"
HOST="$SRC_DIR/runtime/host.mjs"

mkdir -p "$SCRIPT_DIR/expected"
n=0
while IFS=$'\t' read -r name fixture; do
    [[ -z "${name:-}" || "$name" == \#* ]] && continue
    wat="$BUILD_DIR/e2e_$name.wat"; wasm="$BUILD_DIR/e2e_$name.wasm"
    "$BIN" "$SRC_DIR/$fixture" -o "$wat" >/dev/null || { echo "compile fail: $name" >&2; continue; }
    wasm-as --all-features --disable-custom-descriptors -o "$wasm" "$wat" || { echo "asm fail: $name" >&2; continue; }
    node --experimental-wasm-exnref "$HOST" "$wasm" > "$SCRIPT_DIR/expected/$name.txt" 2>/dev/null
    n=$((n+1))
done < "$SCRIPT_DIR/manifest.tsv"
echo "regenerated $n golden(s) in $SCRIPT_DIR/expected"
