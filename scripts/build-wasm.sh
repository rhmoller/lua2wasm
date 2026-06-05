#!/usr/bin/env bash
# Compile lua2wasm itself to WebAssembly with plain clang + wasm-ld — no
# Emscripten, no wasi-sdk. The compiler becomes an ordinary freestanding
# wasm32 module (its own linear memory, its own libc from src/freestanding/),
# suitable for the in-browser playground and for embedding into a C game
# engine that runs wasm the same way.
#
# Produces:  build-wasm/lua2wasm.wasm
# Imports (env):  abort()  log(ptr,len)         — supplied by the embedder
# Exports:  lua2wasm_compile[_ex], lua2wasm_assemble, lua2wasm_dce_dead_names,
#           lua2wasm_free, malloc, free, memory
#
# Usage: scripts/build-wasm.sh   (needs clang >= 19 and wasm-ld on PATH)
set -euo pipefail
cd "$(dirname "$0")/.."

for tool in clang wasm-ld; do
    command -v "$tool" >/dev/null || { echo "$tool not on PATH" >&2; exit 1; }
done

OUT=build-wasm
mkdir -p "$OUT"

# Compiler core (same translation units as the native build) + the wasm entry
# shim + the freestanding C runtime.
APP_SRC=(
    src/ast.c
    src/lexer.c
    src/parser.c
    src/wat_builder.c
    src/codegen.c
    src/builtins.c
    src/xalloc.c
    src/wat2wasm.c
    src/wasm_entry.c
    src/freestanding/baselib.c
    src/freestanding/alloc.c
    src/freestanding/fmt.c
)
# Vendored third-party (compiled with warnings off; legacy/foreign C).
VENDOR_C=(
    src/freestanding/dtoa_glue.c          # -> third_party/dtoa/dtoa.c (strtod + dtoa)
    third_party/wasm-sjlj/wasm_sjlj.c     # setjmp/longjmp support runtime
)

DEBUG="${DEBUG:-0}"
if [[ "$DEBUG" == 1 ]]; then
    OPT="-O0 -g"
else
    OPT="-O2"
fi

# Target flags shared by every TU and the final link.
#   -mexception-handling  enables the Wasm EH feature that the setjmp/longjmp
#                         lowering and the __c_longjmp tag (.S) both require.
# The setjmp/longjmp *lowering* (-mllvm -wasm-enable-sjlj) is a compile-only
# pass, added per-TU in compile() so it doesn't leak into the link command.
TARGET=(--target=wasm32-unknown-unknown -ffreestanding -nostdlib -mexception-handling)
SJLJ=(-mllvm -wasm-enable-sjlj)
INCLUDE=(-Isrc -Isrc/freestanding/include)
# #embed "prelude.wat" in codegen.c resolves against --embed-dir, not -I.
EMBED=(--embed-dir=runtime)

OBJ="$OUT/obj"
mkdir -p "$OBJ"
objs=()

compile() { # compile <src> <extra-flags...>
    local src="$1"; shift
    local obj="$OBJ/$(echo "$src" | tr '/.' '__').o"
    clang "${TARGET[@]}" "${SJLJ[@]}" $OPT "${INCLUDE[@]}" "${EMBED[@]}" "$@" -c "$src" -o "$obj"
    objs+=("$obj")
}

for s in "${APP_SRC[@]}"; do
    compile "$s" -std=c23 -Wall -Wextra -Wpedantic -Wno-unused-parameter
done
for s in "${VENDOR_C[@]}"; do
    compile "$s" -w
done
# The __c_longjmp Wasm EH tag (assembly).
clang "${TARGET[@]}" -c third_party/wasm-sjlj/wasm_sjlj_tag.S -o "$OBJ/sjlj_tag.o"
objs+=("$OBJ/sjlj_tag.o")

# Link. No --allow-undefined: the only unresolved symbols permitted are the
# host imports, which carry import_module/import_name attributes and so are not
# treated as errors. Anything else unresolved is a real bug and fails the link.
EXPORTS=(
    --export=lua2wasm_compile
    --export=lua2wasm_compile_ex
    --export=lua2wasm_assemble
    --export=lua2wasm_dce_dead_names
    --export=lua2wasm_free
    --export=malloc
    --export=free
)
LDFLAGS=(-Wl,--no-entry -Wl,--export-memory -Wl,-z,stack-size=8388608)
for e in "${EXPORTS[@]}"; do LDFLAGS+=("-Wl,$e"); done
[[ "$DEBUG" == 1 ]] || LDFLAGS+=(-Wl,--strip-debug -Wl,--gc-sections)

clang "${TARGET[@]}" "${objs[@]}" "${LDFLAGS[@]}" -o "$OUT/lua2wasm.wasm"

echo "wrote $OUT/lua2wasm.wasm"
ls -la "$OUT/lua2wasm.wasm"
