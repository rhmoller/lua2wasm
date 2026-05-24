# lua2wasm

Ahead-of-time compiler: **Lua 5.5 source → standalone WebAssembly**, written in
C23. No interpreter, no bytecode VM, no bundled GC. Long-form mission in
[`GOAL.md`](GOAL.md); full feature matrix in [`README.md`](README.md).

## Hard constraints (never violate)

- **No linear memory.** Every Lua value is a host-GC object: `$LuaString` wraps
  `(array i8)`, `$LuaTable` is a WasmGC struct, `$LuaClosure` is a struct of
  `(funcref, upvalues)`. Don't propose a hand-rolled allocator or `memory`.
- **No bundled garbage collector** — the host's GC owns every value's lifetime.
- **No bytecode interpreter** — everything is statically lowered to WASM. Code
  not lowerable at compile time is a compile-time *error*, not a runtime path.
- Output leans on WasmGC + typed function refs + exception-handling proposals.
  Lean into the WASM type system (`i31ref`, `rec` groups, `call_ref`,
  `try_table`), don't work around it.

## Build & test

```sh
CC=clang cmake -S . -B build -G Ninja      # configure (Debug by default)
cmake --build build                        # build the native compiler
ctest --test-dir build --output-on-failure # run the full suite (must be green)
```

Run a single test: `ctest --test-dir build -R test_e2e_<name> --output-on-failure`.

Needs: clang ≥ 19 (C23 `#embed` of the prelude), cmake ≥ 3.25, Node ≥ 22.
The WAT→wasm assembler is built in (`src/wat2wasm.c`, also the standalone
`wat2wasm` CLI), so Binaryen's `wasm-as` is no longer required — it's only
used as an optional differential oracle by the `wat2wasm` unit tests.

## Compile & run a Lua program

```sh
./build/lua2wasm input.lua -o out.wasm   # binary module directly (-o out.wat for text)
node --experimental-wasm-exnref runtime/host.mjs out.wasm
```

Multi-file: `-m util.lua` makes `require("util")` work (baked in at compile time).
Compatibility scorecard over the official Lua suite: `scripts/smoke-official-tests.sh`.

`.wasm` output runs dead-code elimination (unreachable functions + globals,
plus the function-type signatures they leave orphaned) by default — `--no-dce`
disables it. `--tree-shake` additionally drops
builtins the program never names (big size win; breaks dynamic `_G` lookups
of un-named builtins). The DCE pass lives in `wat2wasm` (assembler), so the
`wat2wasm` CLI takes `--dce` to opt in.

## The phase rule — *if you can't print it, you didn't build it*

New language features land behind an end-to-end fixture **before** parser syntax:

1. Add `tests/fixtures/<feature>.lua` that prints what the feature enables.
2. Add a row to `tests/e2e/manifest.tsv` (`<name>\t<fixture>`) + a golden in
   `tests/e2e/expected/<name>.txt` (capture with `tests/e2e/regen.sh`). CMake
   auto-registers `test_e2e_<name>`. Custom drivers (stdin/stderr/`-m`/multi-run)
   get a standalone `tests/test_e2e_<feature>.sh` registered in `CMakeLists.txt`.
3. Confirm it fails for the right reason; then implement lexer → parser → codegen.
4. Land fixture + harness + implementation in **one commit**.

Bug fixes follow the same shape: failing test first, fix second, same commit.

## Conventions

- C23, four-space indents, enforced by clang-format (`.clang-format`). Run
  `cmake --build build --target format` (or enable `.githooks/pre-commit` via
  `git config core.hooksPath .githooks`). Keep `-Wall -Wextra -Wpedantic` clean.
- The runtime prelude is `runtime/prelude.wat`, embedded via C23 `#embed` — edit
  it as WAT, not as a C string. Editing it re-links `codegen.c`.
- Reuse codegen helpers (`emit_args_array`, etc.) over re-open-coding multi-value
  patterns.
- Error messages: match reference Lua **semantically**, not 1:1 on text/chunk-name.
- Conventional Commits (`feat:`/`fix:`/`refactor:`/`test:`/`docs:`/`chore:`/`build:`),
  scope when helpful. **No AI-attribution trailers.** Commit directly to `main`
  (solo project). No emoji in source/commits unless asked.

## Layout

| Path | Job |
|------|-----|
| `src/lexer.{c,h}`   | full Lua 5.5 lexer |
| `src/parser.{c,h}`  | recursive-descent + Pratt; scope & upvalue analysis |
| `src/ast.{c,h}`     | tagged-union AST, bump-allocator pool |
| `src/codegen.{c,h}` | emits WAT via `WatBuilder`; embeds `runtime/prelude.wat` |
| `src/builtins.{c,h}`| single source of truth: builtin name → wasm symbol |
| `src/wat_builder.{c,h}` | dynamic WAT string buffer |
| `src/wat2wasm.{c,h}`| self-contained WAT→wasm binary assembler (lib + `wat2wasm` CLI) |
| `src/xalloc.{c,h}`  | OOM-aborting malloc/realloc wrappers used across the compiler |
| `src/emscripten_entry.c` | browser entry point (`EMSCRIPTEN_KEEPALIVE` exports); Emscripten only |
| `runtime/host.mjs`  | reference host that runs a compiled module |
| `runtime/playground.html` | in-browser editor + compile + run (Emscripten only) |
| `tests/e2e/`        | data-driven e2e suite (manifest + goldens) |

Rolling backlog / punch-list: `notes/codereview.md`. Open a discussion before
large changes.
