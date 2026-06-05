#!/usr/bin/env bash
# Builds the freestanding (plain-clang, no-Emscripten) wasm compiler and checks
# its output is byte-identical to the native build across the e2e fixtures.
# Registered as the ctest `test_freestanding`.
#
# Args: <native lua2wasm> <srcRoot> <binaryDir>
set -euo pipefail
NATIVE="$1"
SRCROOT="$2"
cd "$SRCROOT"

# Needs plain clang + wasm-ld (the freestanding toolchain). If absent, skip
# rather than fail — this keeps the suite green on machines without wasm-ld,
# matching how the project treats other optional tooling.
if ! command -v wasm-ld >/dev/null || ! command -v clang >/dev/null; then
    echo "clang/wasm-ld not available — skipping freestanding build test"
    exit 0
fi

bash scripts/build-wasm.sh >/dev/null

node "$SRCROOT/tests/freestanding/diff_native.mjs" \
    "$NATIVE" "$SRCROOT/build-wasm/lua2wasm.wasm" "$SRCROOT"
