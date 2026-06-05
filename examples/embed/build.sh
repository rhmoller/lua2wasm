#!/usr/bin/env bash
# Build examples/embed/engine.wasm — a C "engine" with the lua2wasm compiler
# linked in. Reuses the compiler's already-compiled freestanding object files
# (scripts/build-wasm.sh leaves them under build-wasm/obj/), compiles engine.c,
# and links the two together. Needs plain clang + wasm-ld (no Emscripten).
set -euo pipefail
cd "$(dirname "$0")/../.."  # repo root

command -v wasm-ld >/dev/null || { echo "wasm-ld not on PATH" >&2; exit 1; }

# 1. Compile the compiler + freestanding libc to objects (build-wasm/obj/*.o).
bash scripts/build-wasm.sh >/dev/null

# 2. Compile the engine against the same target/headers.
TARGET=(--target=wasm32-unknown-unknown -ffreestanding -nostdlib -mexception-handling)
clang "${TARGET[@]}" -O2 -std=c23 -Isrc -Isrc/freestanding/include \
    -Wall -Wextra -c examples/embed/engine.c -o build-wasm/obj/engine.o

# 3. Link engine.c with the compiler objects into engine.wasm. The only
#    undefined symbols are env.abort / env.log (host imports). Exports: the
#    engine API plus malloc/free (the broker stages the Lua source string) and
#    memory.
clang "${TARGET[@]}" build-wasm/obj/*.o \
    -Wl,--no-entry -Wl,--export-memory -Wl,-z,stack-size=8388608 \
    -Wl,--export=engine_build \
    -Wl,--export=engine_on_value \
    -Wl,--export=engine_total \
    -Wl,--export=malloc \
    -Wl,--export=free \
    -o examples/embed/engine.wasm

echo "wrote examples/embed/engine.wasm ($(stat -c%s examples/embed/engine.wasm) bytes)"
