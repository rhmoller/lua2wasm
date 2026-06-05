# Embedding lua2wasm for scripting — proof of concept

This is a runnable PoC of the scenario: **a C application/game, compiled to
WebAssembly, targeting the web, that embeds the lua2wasm compiler so it can run
Lua scripts.** It proves the whole loop and makes the real constraints concrete.

```sh
examples/embed/build.sh          # build engine.wasm (needs clang + wasm-ld)
node examples/embed/demo.mjs      # run the two demos
```

## What's here

| File | Role |
|------|------|
| `engine.c` | A stand-in C "engine" with the lua2wasm compiler **linked in**. Compiles Lua → wasm bytes in its own linear memory (`engine_build`); receives numbers from running scripts (`engine_on_value`). |
| `build.sh` | Reuses the compiler's freestanding object files (`scripts/build-wasm.sh`), compiles `engine.c`, links `engine.wasm`. Plain clang/wasm-ld, no Emscripten. |
| `broker.mjs` | The JS orchestrator: instantiates produced modules, wires imports/exports, marshals values. |
| `demo.mjs` | Drives it: compile Lua at runtime, run it, move data both directions. |

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

## What this PoC does **not** do (the real next step)

The interaction here is **run-a-script**: call `main()`, and the script talks to
the world through host imports. It does *not* call a **named Lua function with
arguments and read its result** — the keystone for game-style scripting
(`on_update(dt)`, `on_collision(a, b)`, registering callbacks). Demo 2 fakes a
per-frame loop by re-instantiating a *stateless* script each frame and feeding
input through `read_num`; a real engine wants one persistent script instance
whose functions it calls repeatedly.

That keystone needs a small, real codegen change (not a PoC hack), because:

- `main` is exported with **no result**, so a chunk's return value can't reach
  the host.
- There is **no exported call primitive**. The runtime prelude already has the
  internal `$lua_call (closure, args) → results` helper and a `$g_globals`
  table — what's missing is an **exported** `lua_call` (look up a global / take a
  closure ref, build an args array, invoke, return the result) plus
  `lua_make_string` so the host can pass string args.
- Adding any export touches the shared prelude, so **every golden changes** —
  it's a proper feature under the repo's phase rule (fixture + goldens +
  implementation in one commit), which is why it's out of scope here.

With that one primitive, the broker could expose `call(fnName, ...args)` and the
engine→script direction becomes first-class.

## A bonus the model gives you for free

**Capability sandboxing.** A script can only do what you wire. Instantiate an
untrusted mod's module *without* the `os_*`/`fs_*` imports (see
`instantiateScript` — unwired imports throw on use) and it physically cannot
touch the filesystem or clock. Combined with the engine's own memory/time
limits, that's a strong sandbox with no extra code.
