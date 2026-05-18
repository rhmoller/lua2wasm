# Design: `_G` and the global environment

## Goal

Make `_G` a real first-class Lua table that aliases every global, so
that all of these work:

```lua
x = 1
print(_G.x)        --> 1
_G.y = 2
print(y)           --> 2
print(_G._G == _G) --> true
for k, v in pairs(_G) do ... end   -- iterates every global
print = nil
pcall(print, "x")  --> false, "attempt to call ..."  (rebinding works)
```

The Lua 5.5 spec says: every global is an entry in `_G` (which is also
`_ENV` at chunk scope). This is normative — Plan A (one-table reification)
is the only spec-faithful design.

## Storage

Single mutable wasm global:

```wat
(global $g_globals (mut (ref null $LuaTable)) (ref.null $LuaTable))
```

Initialized in `$stdlib_init` to a fresh `$tab_new` populated with:

| Key            | Value                                                  |
|----------------|--------------------------------------------------------|
| `"_VERSION"`   | `$LuaString "Lua 5.5"`                                 |
| `"math"`       | the math library table                                 |
| `"string"`     | the string library table                               |
| `"io"`         | the io library table                                   |
| `"table"`      | the table library table                                |
| `"utf8"`       | the utf8 library table                                 |
| `"print"`      | `$g_builtin_print` (the closure)                       |
| `"error"`      | `$g_builtin_error`                                     |
| ... etc ...    | every other top-level builtin                          |
| `"_G"`         | the table itself (self-reference)                      |

The `_G` self-reference works because `$tab_set` accepts a `$LuaTable` as
a value (it's `anyref`).

## Codegen changes

All four global-access call sites in `codegen.c` flip to table-based:

### `VAR_BUILTIN` read
Old: `(global.get $g_<builtin_func_name>)`.
New: `(call $tab_get (ref.as_non_null (global.get $g_globals)) (<key string>))`.

### `VAR_GLOBAL` read
Old: `(global.get $g_user_N)`.
New: `(call $tab_get (ref.as_non_null (global.get $g_globals)) (<key string>))`.

### `VAR_GLOBAL` write
Old: `(global.set $g_user_N <value>)`.
New: `(call $tab_set (ref.as_non_null (global.get $g_globals)) (<key string>) <value>)`.

### Implicit-global creation
Same as VAR_GLOBAL write — `$tab_set` creates the entry if absent.

The `<key string>` is built once per name via `strpool_add` (same
mechanism used for table-field keys like `t.field`). Each access site
emits `(struct.new $LuaString (array.new_data $LuaArr $str_data (i32.const
OFF) (i32.const LEN)))` — three lines, no allocation past the data segment.

## What stays unchanged

- The `$g_builtin_*` wasm globals (closure storage). The prelude itself
  references some directly (`$builtin_ipairs` -> `$g_builtin_ipairs_iter`,
  `$builtin_pairs` -> `$g_builtin_next`). User code never references them
  by their `$g_*` name — it goes through `$g_globals`.
- The parser's globals symbol table. It still tracks names (used to
  decide VAR_GLOBAL vs VAR_LOCAL). The "index" assigned to each global
  becomes a strpool-offset accessor rather than a wasm-global-slot index.

## What goes away

- The `$g_user_<idx>` per-user-global wasm slots. No emission, no
  initialization. Library tables are inserted directly into `$g_globals`
  by `$stdlib_init`.

## Pre-declared `_G`

Add `_G` to the parser's pre-declared globals list (alongside `math`,
`string`, etc.). At codegen, its initialization is the self-reference
above — handled as a special case in `$stdlib_init` since it's a
"library global" that resolves to `$g_globals` itself rather than to a
fresh library table.

## Performance impact

Old global read: 1 wasm-global load (~1 instruction).
New: hash + linear probe in `$tab_get` (~5-10 instructions in WAT).

Builtins (the hot path) take the bigger hit: `print(...)` becomes a
table lookup before the call. But reference Lua does exactly the same
thing — `_ENV.print` is a bytecode lookup every call. We're matching
real-Lua's perf model, not regressing.

Real programs cache builtins to locals when they matter
(`local print = print`); that pattern remains optimal here.

## Migration plan (one PR)

1. Add the `$g_globals` declaration in the prelude.
2. Rewrite `$stdlib_init` to build the unified table (instead of
   per-library `$g_user_<idx>`).
3. Pre-declare `_G` in the parser; in `$stdlib_init` map it to the
   table itself.
4. Switch `emit_var_read` and `emit_target_open` for VAR_BUILTIN /
   VAR_GLOBAL to emit `$tab_get` / `$tab_set` on `$g_globals`.
5. Drop the per-user-global wasm-global emission from codegen.
6. Run the suite. Anything that breaks tells us what we missed.

## Test coverage

A new fixture exercising:

- `_G.x` read / write equivalence with bare `x`.
- `_G._G == _G`.
- `_G.print = nil; pcall(print)` errors.
- `for k, v in pairs(_G) do` iterates every entry.
- Library access through `_G`: `_G.math.floor(1.5) == 1`.
- `_G` itself is a table: `type(_G) == "table"`, `getmetatable(_G) == nil`.

## Out of scope

- `_ENV` as a per-chunk lexical: Lua 5.5 still has `_ENV`, but it lives
  in chunk-level scope. Implementing the `_ENV` lexical (so user can
  shadow it locally to sandbox a chunk) is meaningfully more work —
  defer to a future milestone if a real use case comes up.
- Strict mode (`global <const> *` opt-in). Reuses the same plumbing
  once `_G` lands.
