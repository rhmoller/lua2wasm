# Embedding lua2wasm for scripting — proof of concept

This is a runnable PoC of the scenario: **a C application/game, compiled to
WebAssembly, targeting the web, that embeds the lua2wasm compiler so it can run
Lua scripts.** It proves the whole loop and makes the real constraints concrete.

```sh
examples/embed/build.sh                              # build engine.wasm (needs clang + wasm-ld)
node --experimental-wasm-exnref examples/embed/demo.mjs   # run the three demos
```

(The `--experimental-wasm-exnref` flag is what Node needs to run the Lua
modules' exception-handling opcodes — the same flag the rest of the project's
runtime uses. A browser supports them natively.)

## What's here

| File | Role |
|------|------|
| `engine.c` | A stand-in C "engine" with the lua2wasm compiler **linked in**. Compiles Lua → wasm bytes in its own linear memory (`engine_build`); receives numbers from running scripts (`engine_on_value`). |
| `build.sh` | Reuses the compiler's freestanding object files (`scripts/build-wasm.sh`), compiles `engine.c`, links `engine.wasm`. Plain clang/wasm-ld, no Emscripten. |
| `broker.mjs` | The JS orchestrator: instantiates produced modules, wires imports/exports, marshals values, and wraps the host-call ABI (`callLua`). |
| `demo.mjs` | Three demos: script→engine, engine→script per-frame, and the engine calling named Lua functions on a persistent instance (`lua_call`). |

## The architecture this demonstrates

```
        ┌──────────────── Browser / Node: JS broker ────────────────┐
        │                                                           │
   engine.wasm  ──(1) engine_build(src) → script bytes──►  broker   │
   (C + compiler        (compiled in engine's linear memory)   │     │
    linked in)                                                 ▼     │
        ▲                                   (2) WebAssembly.instantiate
        │                                          │                 │
        │   (3) host.print(luaval) ──► broker ──► lua_get_int(luaval) │
        │        ◄── engine_on_value(double) ◄──── (reduce GC→prim)   │
        │                                       script.wasm (WasmGC)  │
        │   (3') host.read_num() ◄── broker ◄── lua_make_int(frame)   │
        └───────────────────────────────────────────────────────────┘
```

Three facts the PoC makes concrete:

1. **The compiler links into a C host with no glue.** `engine_build` just calls
   the compiler's `lua2wasm_compile_ex` + `lua2wasm_assemble` (linked from
   `src/`). Because both are the same freestanding wasm build, they share one
   module and one linear memory.

2. **A wasm module can't instantiate another — JS must.** `engine.wasm`
   *produces* the script bytes but cannot run them; the broker calls
   `WebAssembly.instantiate`. Your engine being wasm doesn't remove the JS
   layer, it adds a second module for JS to broker. (The wiring is one-time; you
   can pass one module's exports as another's imports so the per-call path is
   direct wasm↔wasm — except for value marshaling, see #3.)

3. **The engine can't touch Lua values; JS reduces them to primitives.** Lua
   values are WasmGC objects in the *script's* heap. A linear-memory C function
   can't even name that type, so it deals only in `double`/`i64`. The broker
   bridges by calling the script's own `lua_get_int`/`lua_get_float` (GC→scalar)
   and `lua_make_int`/`lua_make_float` (scalar→GC). That's `engine_on_value`
   receiving a plain `double` in demo 1, and `read_num` returning a freshly
   boxed number in demo 2.

## Calling named Lua functions: the host-call ABI (`--embed-api`)

Demo 1 and 2 are **run-a-script**: call `main()`, and the script talks to the
world through host imports. Demo 3 is the real scripting model — the engine
invokes a **named Lua function with arguments and reads its result**, against
**one persistent instance** whose state survives between calls
(`damage(30)` then `damage(25)` sees `hp` decrement). That's what game-style
scripting needs (`on_update(dt)`, `on_collision(a, b)`, ...).

It's enabled by compiling with **`--embed-api`** (here `engine_build` passes
`embed_api = 1`). That exports a small host-call ABI on the produced module:

| Export | Use |
|--------|-----|
| `lua_str_new(n)` / `lua_str_setb(s,i,b)` | build a Lua string (a name or a string arg) |
| `lua_get_global(name)` | fetch a global (your function) by name |
| `lua_args_new(n)` / `lua_args_set(a,i,v)` | build an argument list |
| `lua_call(fn, args)` | invoke; returns a results array (Lua errors throw the `LuaError` tag) |
| `lua_args_len(r)` / `lua_args_get(r,i)` | read the results (handles multiple returns) |

`broker.mjs` wraps these as `callLua(S, name, ...args)`. Because the ABI can
reach any global and call anything, `--embed-api` keeps the whole stdlib live
(no tree-shaking) and runs `stdlib_init`, so the modules are larger than a
tree-shaken run-once script — the trade you make for a callable script.

The general harness for this lives in `tests/test_embed_api.mjs`.

## A bonus the model gives you for free

**Capability sandboxing.** A script can only do what you wire. Instantiate an
untrusted mod's module *without* the `os_*`/`fs_*` imports (see
`instantiateScript` — unwired imports throw on use) and it physically cannot
touch the filesystem or clock. Combined with the engine's own memory/time
limits, that's a strong sandbox with no extra code.
