#!/usr/bin/env bash
# Compile tests/fixtures/embed_api.lua with --embed-api and drive the host-call
# ABI from Node (tests/test_embed_api.mjs). Registered as ctest test_embed_api.
# Args: <lua2wasm binary> <srcRoot> <binaryDir>
set -euo pipefail
BIN="$1"
SRCROOT="$2"
BINDIR="$3"

OUT="$BINDIR/embed_api.wasm"
"$BIN" --embed-api "$SRCROOT/tests/fixtures/embed_api.lua" -o "$OUT"

# The compiled module uses Wasm EH, so Node needs --experimental-wasm-exnref
# (the same flag the rest of the suite runs modules under).
node --experimental-wasm-exnref "$SRCROOT/tests/test_embed_api.mjs" "$OUT"
