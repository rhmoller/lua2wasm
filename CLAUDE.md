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
disables it. Tree-shaking (dropping builtins/libraries the program never
references) is **automatic** for *globally closed* programs — those that never
mention `_G`/`_ENV` and never call `load`/`require`, so the referenced set is
statically complete (`program_needs_runtime`'s sibling: the `escaped` flag in
`compute_live_set`). String method/field access keeps the `string` library
(string metatable `__index`). `--tree-shake` *forces* it even when not closed
(can break dynamic `_G` lookups of un-named builtins). The whole-program skip of
`$stdlib_init` (when the program observes no runtime state) is the degenerate
case. The DCE pass lives in `wat2wasm` (assembler), so the `wat2wasm` CLI takes
`--dce` to opt in.

Numeric/call specialization (int/float unboxing, typed direct-call entries,
comparison specialization) is **on by default**; `-O0` selects the boxed
fallback. The two are behaviour-identical (goldens are shared), so the e2e
suite runs each fixture both ways: the default loop exercises the specialized
path, a `-O0` loop (`test_e2e_o0_*`) guards the fallback.

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

## Property-based & differential testing

The phase-rule goldens above pin one output per case. For logic-heavy code —
lexer, parser, pattern matcher, number formatter/parser, table-key
normalization — also assert *properties* that hold across many inputs.

The property oracle is **reference Lua 5.5**; the master invariant is
`run(compile(p)) == lua5.5(p)` for any program `p`. It lives in
`scripts/diff-test.sh` (CTest `test_diff_reference`): a curated corpus under
`tests/diff/cases/*.lua` diffed against goldens captured from `lua5.5`
(`scripts/diff-test.sh --regen`; `lua5.5` needed only at regen time).
`tests/diff/manifest.tsv` tags each case `pass` (must match) or `xfail` (a
captured bug — the harness goes red if it *starts* matching, so you promote it
to `pass`). `scripts/smoke-official-tests.sh` scores the upstream Lua suite.

Reach for a property instead of a single golden when the input space is large
and the rule is declarative (matcher, formatter, arithmetic, key
normalization): enumerate or generate inputs and diff the batch against
`lua5.5`. Stick to invariants reference Lua actually obeys — e.g.
`string.char(string.byte(s, 1, #s)) == s` for any byte string and "integer ops
wrap mod 2^64" hold; `tonumber(tostring(x))` is *not* a float identity (Lua
prints lossy `%.14g`).

Generative coverage lives in `scripts/diff-fuzz.mjs`: it emits random Lua in
the supported subset, runs each program through both `lua2wasm`→node and
`lua5.5`, and reports/shrinks any divergence (seeded — a seed reproduces a
program). It needs `lua5.5` live (like `--regen`) so it is a local/nightly
discovery tool, **not** part of `ctest`; its findings are the durable net.
Expressions are pcall-wrapped (`print(ok, ...)`) so error *text* is never
diffed (semantic-not-textual). It deliberately skips non-portable ops
(transcendentals, `^` with fractional exponent, NaN sign). When it finds a
counterexample, **shrink it and check it in as a `tests/diff` case** (the
`--emit NAME` flag scaffolds one as `xfail`) before fixing, then promote to
`pass`. Run: `node scripts/diff-fuzz.mjs --count 5000 [--phase numeric|format]`.

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
