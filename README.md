# lua2wasm

A clean-room, **ahead-of-time** Lua 5.4 → WebAssembly compiler that targets the
modern WASM stack (GC, typed function references, i31ref, exception handling).
Lua values live as host-GC objects, not in linear memory.

This is a research / educational project. The plan, including the value
representation and WASM feature inventory, lives at
`~/.claude/plans/let-s-try-something-crazy-robust-graham.md`.

## Status

Milestone 1 (v1): the program `print(1 + 2)` compiles end-to-end and runs in
Node ≥ 22 (and any GC-capable browser).

Supported in v1:

- integer literals (i31 range)
- `+ - * /` on integers
- the single builtin `print(x)`

Everything else (variables, strings, tables, control flow, closures, stdlib) is
on the roadmap and intentionally not implemented yet.

## Build & test

Requirements: `clang` (C23), `cmake` ≥ 3.25, `binaryen` (for `wasm-as`), Node ≥ 22.

(We use Binaryen's `wasm-as` rather than `wat2wasm` because the wabt
shipped on Arch as of mid-2026 does not yet accept the modern GC text
format — `anyref`, recursive `(ref null $t)` refs, etc.)

```sh
cmake -S . -B build
cmake --build build
ctest --test-dir build --output-on-failure
```

The `test_e2e_print_sum` test compiles `tests/fixtures/print_sum.lua`,
runs `wat2wasm`, and executes the resulting module under Node.

## Manual run

```sh
./build/lua2wasm tests/fixtures/print_sum.lua -o /tmp/sum.wat
wasm-as --all-features -o /tmp/sum.wasm /tmp/sum.wat
node runtime/host.mjs /tmp/sum.wasm    # prints: 3
```

## Browser sanity

```sh
( cd build && python3 -m http.server 8000 ) &
# open http://localhost:8000/../runtime/index.html?mod=print_sum.wasm
```
