# Project Goal

## Mission

Build a clean-room, ahead-of-time **Lua 5.5 → WebAssembly** compiler that
treats the modern WASM type system as a first-class target — not as a portable
assembler with a hand-rolled allocator on top.

The compiler is written in C23. The output is a standalone `.wasm` module that
runs in any GC-capable host (browser V8 / SpiderMonkey, Node ≥ 22). The
project's signature constraint:

> **No linear memory. No bundled garbage collector. No bytecode interpreter.**
> Every Lua value is a host-GC object (`struct`, `array`, `i31ref`); every Lua
> table is a real WasmGC struct; every Lua closure is a typed function
> reference. The host runtime *is* the Lua VM.

## Why this is worth doing

1. **A real test of WasmGC.** WasmGC shipped in browsers in late 2023 and
   Safari dropped its objection in late 2025, but few real compilers exercise
   the full type system (subtyping, recursive types, i31ref, exception
   handling). Lua's dynamic-typed-but-structured semantics are a good fit and
   a good stress test.
2. **Educational density.** Lua is small enough to fit a clean-room compiler
   in a few thousand lines of C, but real enough to surface every interesting
   problem: tagged values, closures with upvalues, proper tail calls, string
   interning, metatables, coroutines.
3. **A bridge between two ecosystems.** Lua's embedding ergonomics + the
   browser's reach. If the pipeline works, a Lua script can ship to the web
   as ~10 KB of GC'd WASM that the host can introspect.

## Non-goals (explicit scope cuts)

- **Not a Lua interpreter port.** We are not compiling reference Lua's
  C source to WASM. Every line of the runtime is ours.
- **Not source-compatible with reference Lua's C API.** We're targeting the
  language, not the embedding API.
- **Not optimizing for binary size or peak throughput** during early phases.
  Correctness and clean codegen first; the WASM toolchain (Binaryen `wasm-opt`)
  handles optimization once the shape is right.
- **No linear memory fallback.** If a feature genuinely cannot be done in
  WasmGC, we either wait for the relevant proposal to ship (e.g. stack
  switching for coroutines) or document the gap.
- **No bytecode VM** as an intermediate step. We compile directly to WASM.

## Architectural commitments

- **Frontend in C23 with clang + CMake.** Tests via vendored µnit. Hand-rolled
  recursive-descent parser, no parser generator.
- **Emit WAT text, post-process with Binaryen's `wasm-as`.** Human-readable
  output makes everything debuggable; we can swap in a binary encoder later
  behind the same builder API.
- **Static prelude.** Runtime helpers (`$lua_add`, `$lua_eq`, `$lua_concat`,
  string conversion, …) are written as WAT and embedded as a C string
  literal. They are *not* generated per program.
- **Value representation locked early.** See the table in README. New value
  kinds get added; existing ones do not change shape.

## Phase plan

Each phase is "tested end-to-end on a fixture Lua program before declaring done."
The fixture grows monotonically — new phases must not break old fixtures.

### Phase 1 — Hello world ✓ **done**

Goal: prove the entire pipeline (lexer, parser, codegen, WAT emission,
`wasm-as`, host runtime) for the smallest non-trivial program.

- Fixture: `print(1 + 2)` → `3`
- Stretch: just one expression, just one builtin.
- Lock in: project layout, build system, test harness, value rep for ints.

### Phase 2 — Imperative subset ✓ **done**

Goal: turn the compiler into something you could plausibly write a fizzbuzz in.

- Full Lua 5.5 lexical surface (minus long string brackets and exotic escapes).
- All literal kinds: nil, booleans, ints, floats, strings.
- Locals + assignment.
- `if/elseif/else`, `while`, bare `do`.
- All non-table operators including short-circuit `and`/`or`, length `#`,
  concat `..`.
- Mixed int/float arithmetic with Lua promotion rules.
- Fixture: `tests/fixtures/milestone2.lua` exercising the above.

### Phase 3 — Functions and closures ✓ **done** (3a + 3b)

Goal: first-class functions with proper Lua semantics. Unlocks recursion,
real `return` values, and most of the standard library.

- `function f(a, b) ... end` and anonymous `function ... end` expressions.
- Multiple return values; multi-assign `a, b = f()`.
- Varargs: `function f(...)` / `function f(a, ...)`, with `...` spliced
  into call arguments, returns, and table constructors.
- Upvalue capture: closures that reference enclosing locals.
- Proper tail calls via WASM `return_call_ref`.
- `$LuaClosure` = struct of `(funcref + upvalue array)`.
- Fixture: recursive `fact(n)`, plus a closure-returning-closure example
  (counter, accumulator), plus a deeply tail-recursive function that would
  blow the stack without TCO.

Acceptance: every fixture from phase 2 still passes; the `print` builtin
becomes a normal `$LuaClosure` instead of a hardcoded codegen path.

### Phase 4 — Tables ✓ **done**

Goal: the keystone of Lua. Once tables work, most idiomatic Lua compiles.

- `$LuaTable` struct with two fields: array part `(ref (array (mut anyref)))`
  and hash part (open-addressing or chained, TBD).
- Table constructors: `{1, 2, 3}`, `{x = 1, y = 2}`, mixed.
- Indexing: `t[k]`, `t.k`, assignment to indices.
- Length operator `#` extends to tables (the "border" rule).
- Fixture: a hand-coded linked list, a small key-value lookup, iteration via
  manual index walk (no `pairs` yet).

### Phase 5 — Control flow, globals, `for` ✓ **done** (modulo `goto`)

Goal: the rest of the grammar. After this, the only language gaps are error
handling, metatables, and coroutines.

- Numeric `for i = a, b, c do ... end` — control variable is **const**
  (Lua 5.5 rule).
- Generic `for k, v in iter do ... end` (depends on phase 3's multi-return).
- `repeat ... until cond`, `break`, `goto` / `::label::`.
- Globals with Lua 5.5 **`global` declarations** — undeclared global access
  is a compile-time error.
- Fixture: a self-contained "data crunch" script using all of the above.

### Phase 6 — Errors ✓ **done**

Goal: `error` and `pcall` mapped onto WASM exception handling.

- `error(v)` → `throw $LuaError v`.
- `pcall(f, ...)` → `try_table` returning `(ok, result_or_err)`.
- Stack-unwinding semantics preserved.
- Fixture: an arithmetic-on-nil case wrapped in `pcall`, plus deliberate
  `error("...")` propagation.

### Phase 7 — Minimal stdlib ✓ **done** (subset: tostring/tonumber/type/ipairs/pairs/next/setmetatable/getmetatable + math.{floor,abs,sqrt} + string.{len,sub})

Goal: enough of the standard library that interesting scripts run unmodified.

- `tostring`, `tonumber`, `type`, `select`, `ipairs`, `pairs`, `next`.
- `string`: `len`, `sub`, `upper`, `lower`, `rep`, `format` (subset),
  `byte`, `char`.
- `math`: `floor`, `ceil`, `abs`, `min`, `max`, `huge`, `pi`, `sqrt`,
  `pow` (well, `^`), `random`.
- `table`: `insert`, `remove`, `concat`, `unpack`, `create` (5.5).
- `utf8`: `len`, `offset` (with the 5.5 end-position return), `codepoint`,
  `char`.
- Fixture: a small benchmark suite ported from upstream Lua's own tests.

### Phase 8 — Metatables ✓ **done** (subset: `__index` table/func chain, `__add`, `__eq`)

Goal: `setmetatable`, `getmetatable`, and the core metamethods.

- `__index` (table or function), `__newindex`, `__add`/`__sub`/…,
  `__eq`, `__lt`, `__le`, `__len`, `__call`, `__tostring`.
- `__index` chain walking with cycle detection.
- Fixture: classic OO pattern (`Animal:speak()` with inheritance), an
  immutable wrapper using `__newindex` to forbid writes.

### Phase 9 — Coroutines (when available)

Blocked on: WASM **stack-switching proposal** shipping in browsers
(currently phase 3, prototype in Wasmtime).

- `coroutine.create`, `resume`, `yield`, `wrap`, `status`.
- Until the proposal ships in browsers, we either:
  (a) Stub coroutines with a JS-side trampoline that emulates them, or
  (b) Mark phase 9 as "blocked, target Wasmtime first."

### Phase 10 — Polish, packaging, perf  ✓ **done** (subset: single-file HTML packager + README)

- `wasm-opt` integration in the build pipeline.
- A web playground (Monaco editor + live compile + run) under `runtime/web/`.
- A CLI flag to embed the wasm + a tiny JS loader into a single HTML file
  ("ship a Lua script as a self-contained webpage").
- A benchmark suite vs. reference Lua, vs. LuaJIT, vs. Fengari (Lua in JS).
- A real binary-encoder backend that replaces the WAT/`wasm-as` pipeline.

## Success criteria

This project will be considered "complete enough" when:

1. A non-trivial real-world Lua script (say, the [lua-users wiki's
   ANSI-colour module](https://lua-users.org/wiki/AnsiTerminalColors), or
   the matrix routines from `lua-matrix`) compiles unmodified and runs.
2. The compiled output is competitive in size with hand-written WAT and
   within ~3× of LuaJIT on a small arithmetic-heavy benchmark.
3. A live editor in the browser can compile + run scripts without any
   server-side help.

## Open questions

- **String storage.** Should we eventually adopt the **JS String Builtins**
  proposal so Lua strings *are* JS strings? Trade-off: cheap host interop
  vs. losing the simple `(array i8)` model. Likely yes, when it stabilizes.
- **Number representation under the i31 / float boundary.** Always-box
  vs. our current i31-or-box hybrid. We have evidence the hybrid produces
  noticeably less garbage in tight loops, but no benchmark numbers yet.
- **Source maps.** Worth doing as soon as we have control flow / functions,
  to make browser-side debugging usable.
- **Bootstrap.** Could lua2wasm eventually self-host (compile itself with
  reference Lua → lua2wasm → wasm)? Probably not worth the effort, but a
  fun thought.

## Working norms

- Each phase ends with: an updated fixture, a passing CTest run, an updated
  *Status* section in the README, and a tagged commit.
- New language features land behind an end-to-end fixture before they land
  as syntax in the parser. "If you can't print it, you didn't build it."
- The runtime prelude stays hand-written WAT until it gets unwieldy. When
  it does, we factor it into a separate `runtime/prelude.wat` and `#include`
  it via the build.
- Phase boundaries are commitments to the *user*, not handcuffs. If a small
  feature obviously belongs with the current phase, it lands in the current
  phase.
