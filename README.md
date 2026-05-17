# lua2wasm

A clean-room, **ahead-of-time** Lua 5.5 → WebAssembly compiler, written in C23.
Lua values live as host-GC objects via the WebAssembly GC proposal — no linear
memory, no bundled allocator, no bespoke garbage collector. The browser's V8 /
SpiderMonkey collector *is* the Lua VM's memory manager.

This is a research / educational project. The goal is to push as much of the
runtime into the modern WASM type system as possible, and to learn what Lua
semantics actually demand of a host that already has a managed runtime.

For the long-form mission, non-goals, phase plan, and success criteria, see
[`GOAL.md`](GOAL.md).

## Why Lua 5.5?

Lua 5.5 (Dec 2025) is the current stable language. Targeting it from the start
costs nothing extra and sidesteps a future deprecation cycle. The 5.5-specific
features that affect the compiler frontend:

- **Global variable declarations** — `global x` must be present before any
  use; undeclared global access is a compile-time error.
- **`for`-loop control variables are read-only** — assigning to the loop
  variable inside the body is rejected.
- **Named vararg tables** — cleaner alternative to manually packing `...`.

The 5.5 VM-level wins (60% smaller arrays, incremental major GC, external
strings, generational mode) we get for free: the host runtime owns those
concerns.

## Status

**Milestone 3a (current) — first-class functions and closures.**

| Area | Supported now | Deferred |
|---|---|---|
| Lexer | All keywords, operators, single/double-quoted strings with escapes, integer + float literals, `--[[ ]]` long comments | Long string literals `[[ ]]`, `\xHH`/`\u{…}` escapes, hex/binary number literals |
| Values | `nil`, booleans, integers (i31ref or `$LuaInt` box), floats (`$LuaFloat`), strings (`$LuaString`), **closures (`$LuaClosure`)** | Tables, userdata, threads |
| Statements | `local x = e`, **`local function f(...) end`**, assignment to locals and upvalues, `if/elseif/else`, `while`, bare `do`, expression-statement (call), **`return [expr]`** | `for`, `repeat/until`, `goto/::label::`, top-level `function f() end` (needs globals), multi-assign, multi-return |
| Expressions | All literals, `function(...) ... end`, variable refs (local/upvalue/`print`), N-arg calls, all operators below | Multiple return values, varargs `...` |
| Operators | `+ - * / // % ^`, `== ~= < <= > >=`, `and or not`, `..`, `#` | Bitwise `& \| ~ << >>` (lexed but not codegen'd) |
| Builtins | `print(x)` — now a real `$LuaClosure` stored in a wasm global | The rest of the standard library |
| Runtime | Mixed int/float promotion, short-circuit and/or, string concat (strings only), **uniform calling convention `(closure, args) → anyref`**, **upvalue capture via shared `$Box`** | Proper tail calls (`return_call_ref`), float `%`, float side of `..`, error/pcall |

See [`tests/fixtures/milestone3.lua`](tests/fixtures/milestone3.lua) for what
a working program looks like today — recursion, closures with mutable
captures, transitive upvalue chains.

## Value representation

Every Lua value is uniformly an `anyref`. Decoding:

| Lua value      | WASM representation                                      |
|----------------|----------------------------------------------------------|
| `nil`          | `(ref.null any)`                                         |
| `false`/`true` | global singletons of `(ref $LuaBool)` struct             |
| integer (small)| `i31ref` — unboxed 31-bit tagged int                     |
| integer (big)  | `(ref $LuaInt)` boxing `i64`                             |
| float          | `(ref $LuaFloat)` boxing `f64`                           |
| string         | `(ref $LuaString)` wrapping `(array (mut i8))` (UTF-8)   |
| table*         | `(ref $LuaTable)` — *milestone 3*                        |
| function       | `(ref $LuaClosure)` = `(ref $LuaFn)` code + `(ref $UpvalArr)` upvalues |
| userdata*      | `externref` slot for opaque JS values — *later*          |

The browser's GC owns lifetime for all of these.

## Architecture

```
              ┌─────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐
  Lua source ─▶  lexer  ├──▶│  parser  ├──▶│ codegen  ├──▶│ wasm-as  │──▶ .wasm
              └─────────┘   └──────────┘   └──────────┘   └──────────┘
                                  │              │
                                  │              └─ static WAT prelude
                                  │                 (types, runtime helpers,
                                  │                  arithmetic, comparison,
                                  │                  string ops, decoders)
                                  │
                                  └─ scope resolution: each
                                     identifier → wasm local index
```

The compiler emits **WAT text**, then Binaryen's `wasm-as` assembles it. We
use Binaryen rather than wabt because as of mid-2026 the wabt build shipping
on Arch (1.0.39) doesn't accept modern GC text syntax (`anyref`, recursive
`(ref null $t)` refs).

### Layout

```
src/         lexer, parser, AST, codegen, WAT builder, main()
runtime/     host.mjs (Node), index.html (browser sanity)
tests/       µnit unit tests + bash E2E scripts
third_party/ vendored µnit
```

## Build & test

Requirements:

| Tool       | Version             | Notes                                          |
|------------|---------------------|------------------------------------------------|
| `clang`    | ≥ 16 (for `-std=c23`) | the compiler is written in C23                |
| `cmake`    | ≥ 3.25              |                                                |
| `binaryen` | recent              | provides `wasm-as` (Arch: `pacman -S binaryen`)|
| `node`     | ≥ 22                | needs WasmGC + reference types                 |

```sh
CC=clang cmake -S . -B build -G Ninja
cmake --build build
ctest --test-dir build --output-on-failure
```

The test suite currently has three µnit binaries (lexer, parser, codegen) and
two end-to-end scripts (`print(1+2)` and the milestone-2 fixture). All five
are wired into CTest.

## Manual run

```sh
./build/lua2wasm tests/fixtures/milestone2.lua -o /tmp/m2.wat
wasm-as --all-features -o /tmp/m2.wasm /tmp/m2.wat
node runtime/host.mjs /tmp/m2.wasm
```

## Browser sanity

```sh
( cd build && python3 -m http.server 8000 )
# then open http://localhost:8000/../runtime/index.html?mod=milestone2.wasm
```

`runtime/host.mjs` does not use any Node-specific WASM features; the same
module loads in any GC-capable browser via `runtime/index.html`.

## Roadmap

3. **Functions + closures.** `function` declarations, multi-arg/multi-return,
   upvalue capture, proper tail calls via `return_call_ref`. Unlocks recursion,
   the `return` value path, and most of the stdlib.
4. **Tables.** Array part + hash part as two `$LuaTable` struct fields.
   `t[k]`, `t.k`, table constructors.
5. **Globals (5.5 semantics)** and the `for` loop (with the 5.5 const-control-
   variable rule).
6. **Error handling** via WASM exception handling (`throw` / `try_table`).
7. **Minimal stdlib**: `tostring`, `tonumber`, `string.len/sub/upper/lower`,
   `math.floor/ceil/abs/...`.
8. **Metatables** and `__index` chains.
9. **Coroutines** once the stack-switching proposal ships in browsers.

## Contributing

Commits follow the [Conventional Commits](https://www.conventionalcommits.org/)
format. Common types in this repo: `feat:`, `fix:`, `refactor:`, `test:`,
`docs:`, `chore:`, `build:`. Use a scope when it's useful, e.g.
`feat(parser): handle long-string literals`.

## License

MIT — see [LICENSE](LICENSE).
