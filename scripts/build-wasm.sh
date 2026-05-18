#!/usr/bin/env bash
# Compile lua2wasm itself to WebAssembly with Emscripten.
# Produces:  build-em/lua2wasm.js   build-em/lua2wasm.wasm
# Usage: source ~/code/3rdparty/emsdk/emsdk_env.sh && scripts/build-wasm.sh
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v emcc >/dev/null; then
    echo "emcc not in PATH; source emsdk_env.sh first" >&2
    exit 1
fi

mkdir -p build-em

SRC=(
    src/ast.c
    src/lexer.c
    src/parser.c
    src/wat_builder.c
    src/codegen.c
    src/builtins.c
    src/emscripten_entry.c
)

# -O2 keeps the output small (~100 KB) without taking forever to link.
# MODULARIZE=1 + EXPORT_ES6=1 gives us a clean `import createModule from './lua2wasm.js'`.
# EXPORTED_RUNTIME_METHODS exposes the helpers JS needs to call into C.
DEBUG="${DEBUG:-0}"
if [[ "$DEBUG" == 1 ]]; then
    OPT="-O0 -g3 -s ASSERTIONS=1 -s SAFE_HEAP=1 -s STACK_OVERFLOW_CHECK=2"
else
    OPT="-O2"
fi

emcc "${SRC[@]}" \
    $OPT \
    -std=c2x \
    -Isrc \
    --embed-dir=runtime \
    -s MODULARIZE=1 \
    -s EXPORT_ES6=1 \
    -s EXPORT_NAME=createLua2WasmModule \
    -s ENVIRONMENT=web \
    -s SINGLE_FILE=0 \
    -s ALLOW_MEMORY_GROWTH=1 \
    -s INITIAL_MEMORY=16777216 \
    -s STACK_SIZE=5242880 \
    -s EXPORTED_FUNCTIONS='["_lua2wasm_compile","_lua2wasm_free","_malloc","_free"]' \
    -s EXPORTED_RUNTIME_METHODS='["cwrap","UTF8ToString","stringToUTF8","lengthBytesUTF8","HEAPU8"]' \
    -o build-em/lua2wasm.js

echo "wrote build-em/lua2wasm.{js,wasm}"
ls -la build-em/lua2wasm.{js,wasm}
