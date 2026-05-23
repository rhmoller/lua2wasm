# Lua 5.5 Language Feature Spec

Status legend: ✅ implemented · 🟡 partial · ❌ missing · 🚫 out of scope

Reference: `lua-5.5.0/doc/manual.html` §3 ("The Language"). Section numbers below
mirror the manual so it's easy to cross-check.

---

## 3.1 Lexical conventions

### Identifiers
| Item | Status | Notes |
|---|---|---|
| `[A-Za-z_][A-Za-z0-9_]*`, case-sensitive | ✅ | |
| Reserved word list (22 keywords) | ✅ | `and break do else elseif end false for function goto if in local nil not or repeat return then true until while` |

### Comments
| Item | Status | Notes |
|---|---|---|
| Line comment `-- …` | ✅ | |
| Long comment `--[[ … ]]` (level 0) | ✅ | |
| Long comment `--[=[ … ]=]`, `--[==[ … ]==]` (level N) | ✅ | any level N; `try_open_long_bracket` counts `=`s generically |

### Numeric literals
| Form | Status | Notes |
|---|---|---|
| Decimal int `123` | ✅ | |
| Decimal float `3.14` | ✅ | |
| Exponent `1e10`, `2.5E-3` | ✅ | |
| Hex int `0xFF`, `0Xff` | ✅ | wraps mod 2^64 (long literals denote low 64 bits) |
| Hex float `0x1.8p3`, `0x1p-4` | ✅ | parsed via C99 `strtod`; presence of `.` or `p` forces float |
| Numeric underscores (not Lua std) | 🚫 | not in Lua 5.5 |

### String literals
| Form | Status | Notes |
|---|---|---|
| Short `"…"` and `'…'` | ✅ | |
| Escapes `\n \t \\ \" \' \0 \a \b \f \r \v` | ✅ | |
| `\xHH` (2 hex digits) | ✅ | |
| `\u{H…}` (UTF-8, up to 6-byte form ≤ 0x7FFFFFFF) | ✅ | matches reference Lua's accepted range |
| `\ddd` (1–3 decimal digits) | ✅ | value must fit in a byte (0–255) |
| `\z` (skip following whitespace, incl. newlines) | ✅ | |
| `\<newline>` → literal `\n` | ✅ | CR/LF/CRLF/LFCR all collapse to one `\n` |
| Long bracket `[[ … ]]`, leading newline stripped | ✅ | |
| Long bracket level N `[=[ … ]=]`, `[==[ … ]==]` | ✅ | any level N |

---

## 3.2 Values and types

| Type | Status | Representation |
|---|---|---|
| `nil` | ✅ | host `null` (anyref null) |
| `boolean` | ✅ | `i31ref` tag |
| `number` integer (64-bit) | ✅ | `i31ref` if in 31-bit range, else boxed `$LuaInt` |
| `number` float (IEEE-754 double) | ✅ | boxed `$LuaFloat` |
| `string` | ✅ | `$LuaString` wrapping `(array i8)` |
| `function` | ✅ | `$LuaClosure` = (funcref `$LuaFn`, upvalue array) |
| `table` | ✅ | `$LuaTable` = (keys, vals, n, cap, meta) |
| `thread` (coroutines) | ❌ | blocked on WASM stack-switching |
| `userdata` (light & full) | 🚫 | no embedding API by design |

Type checks (`type(x)`): ✅ returns canonical names. `math.type(x)` for
`integer`/`float` distinction: ✅ returns `"integer"` / `"float"` / `nil` (fail for non-number).

---

## 3.3 Statements

### 3.3.1 Blocks / chunks
| Item | Status | Notes |
|---|---|---|
| Chunk = block; implicit varargs at top level | ✅ | top-level `...` works |
| `do … end` bare block | ✅ | |
| `;` empty statement | ✅ | |

### 3.3.2 Local declarations
| Item | Status | Notes |
|---|---|---|
| `local x` | ✅ | initialized to `nil` |
| `local x, y, z = e1, e2, e3` | ✅ | multi-assign with adjustment |
| `local x = f()` (multret adjusted to 1) | ✅ | |
| `local x, y = f()` (multret expanded) | ✅ | |
| Attribute `local x <const> = …` | ✅ | compile-time rejection of reassignment; prefix form `local <const> a, b` also works |
| Attribute `local x <close> = …` | 🟡 | `__close(value, nil)` called in reverse order at natural block exit; nil/false skipped; early exits (`return`/`break`/`goto`/error) do not yet trigger close |
| Lexical block scoping, shadowing | ✅ | |

### 3.3.3 Assignment
| Item | Status | Notes |
|---|---|---|
| `lhs = expr` simple | ✅ | |
| `a, b, c = e1, e2, e3` multi | ✅ | |
| `a, b = b, a` swap semantics (RHS evaluated first) | ✅ | |
| LHS: `name`, `t.k`, `t[k]` | ✅ | |
| Implicit global assignment | ✅ | `x = 1` at top level creates a global |
| Explicit `global x` declaration | ✅ | non-standard; project convention |

### 3.3.4 Control structures
| Item | Status |
|---|---|
| `if e then … elseif e then … else … end` | ✅ |
| `while e do … end` | ✅ |
| `repeat … until e` (cond sees locals from body) | ✅ |
| `break` | ✅ |
| `return e1, …` (must be last in block) | ✅ |
| `goto label` / `::label::` | ✅ | forward and backward jumps; lowered to WASM `br` on labelled blocks; Lua scoping rule enforced (cannot jump into scope of a local) |

### 3.3.5 For statements
| Item | Status | Notes |
|---|---|---|
| Numeric `for i = a, b do … end` | ✅ | step = 1 |
| Numeric `for i = a, b, c do … end` | ✅ | signed step; int vs float typing per spec |
| Generic `for k in iter do … end` | ✅ | |
| Generic `for k, v[, …] in iter[, state[, init[, closing]]] do … end` | ✅ | closing-value (4th expr) not honoured |

### 3.3.6 Function definitions
| Form | Status |
|---|---|
| `function f() … end` (global, dotted, method) | ✅ |
| `local function f() … end` | ✅ |
| Anonymous `function() … end` expression | ✅ |
| Method definition `function T:m(self_args) … end` | ✅ |
| Method call sugar `obj:m(args)` | ✅ |
| Multiple return values | ✅ |
| Varargs `function(…)` and `function(a, …)` | ✅ |
| `...` spliced into call args / returns / table ctor / multi-assign | ✅ |
| Proper tail calls (`return f(...)`) | ✅ | lowered to `return_call_ref` |

---

## 3.4 Expressions

### 3.4.1 Arithmetic operators
| Op | Status | Notes |
|---|---|---|
| `+` `-` `*` | ✅ | int×int → int, else float |
| `/` (float division, always float) | ✅ | |
| `//` (floor division) | ✅ | int and float forms |
| `%` (modulo) | ✅ | int and float floor-mod; `a - floor(a/b)*b` |
| `^` (exponent, always float) | ✅ | |
| Unary `-` | ✅ | |
| `__add` / `__sub` / `__mul` / `__div` / `__mod` / `__pow` / `__unm` / `__idiv` metamethods | ✅ | all eight; consulted when operand is non-numeric |

### 3.4.2 Bitwise operators
| Op | Status | Notes |
|---|---|---|
| `&` `\|` `~` (xor) `<<` `>>` (binary) | ✅ | 64-bit integer semantics; negative shift counts swap direction; `\|count\| >= 64` yields 0 |
| Unary `~` (bnot) | ✅ | |
| `__band/__bor/__bxor/__bnot/__shl/__shr` metamethods | ✅ | fired when operand is not integer-convertible |

Float operands with no fractional part in signed i64 range are accepted (Lua's "convertible to integer" rule).

### 3.4.3 Coercions and conversions
| Item | Status | Notes |
|---|---|---|
| Int↔float promotion in arithmetic | ✅ | |
| String→number coercion in arithmetic (e.g. `"3" + 1`) | ✅ | via `$coerce_num`; leading/trailing whitespace stripped; `"3e0" + 0` → float |
| Number→string coercion in `..` | ✅ | |
| Integer-valued float comparison rules | ✅ | |

### 3.4.4 Relational operators
| Op | Status | Notes |
|---|---|---|
| `==` `~=` | ✅ | structural for strings; reference equality for tables/functions |
| `<` `<=` `>` `>=` | ✅ | numbers and strings |
| `__eq` metamethod | ✅ | |
| `__lt` / `__le` metamethods | ✅ | |

### 3.4.5 Logical operators
| Op | Status |
|---|---|
| `and` (short-circuit) | ✅ |
| `or` (short-circuit) | ✅ |
| `not` | ✅ |

### 3.4.6 String concatenation
| Item | Status | Notes |
|---|---|---|
| `..` (right-associative) | ✅ | |
| Number→string coercion via `..` | ✅ | |
| `__concat` metamethod | ✅ | fired when either operand is non-string non-number; left operand's handler wins |

### 3.4.7 Length operator
| Item | Status | Notes |
|---|---|---|
| `#s` for strings (byte length) | ✅ | |
| `#t` for tables (border) | ✅ | |
| `__len` metamethod | ✅ | overrides border rule on tables; also fires on other non-string values |

### 3.4.8 Precedence
Matches Lua 5.5 precedence table fully: `or` < `and` < comparisons < `|` < `~` (bxor) < `&` < `<< >>` < `..` < `+ -` < `* / // %` < unary < `^`.

### 3.4.9 Table constructors
| Form | Status |
|---|---|
| `{}` empty | ✅ |
| `{e1, e2, e3}` positional | ✅ |
| `{k1 = v1, k2 = v2}` named | ✅ |
| `{[expr] = v}` computed key | ✅ |
| Mixed | ✅ |
| Last expression spread (`{f()}`, `{...}`) | ✅ |
| Trailing `,` or `;` separator | ✅ |

### 3.4.10 Function calls
| Form | Status | Notes |
|---|---|---|
| `f(args)` | ✅ | |
| `f"string"` (paren-less single string arg) | ✅ | |
| `f{table}` (paren-less single table arg) | ✅ | |
| `obj:method(args)` | ✅ | |
| `__call` metamethod | ✅ | `$lua_call_any` walks the `__call` chain; cycle limit enforced |

### 3.4.11 Function definitions (as expressions)
See §3.3.6. All forms supported.

---

## 3.5 Visibility rules
Lexical scoping + upvalue capture by reference (shared boxes). Transitive
capture across nested closures: ✅.

---

## 3.6 Error handling
| Item | Status | Notes |
|---|---|---|
| `error(v)` raise | ✅ | |
| `error(v, level)` | ✅ | level 0 disables prefix; level N walks the call-frame stack |
| `pcall(f, …)` → `(ok, …)` | ✅ | |
| `xpcall(f, msgh, …)` | ✅ | msgh called on error; its return value is the second result |
| `assert(v[, msg])` | ✅ | |
| Stack tracebacks | 🟡 | `debug.traceback` walks the `$call_lines` frame stack; limited to source positions (no function names, no `debug.getinfo`) |
| Underlying mechanism | — | WASM `throw $LuaError` + `try_table` |

---

## 3.7 Metatables and metamethods

| Metamethod | Status | Notes |
|---|---|---|
| `__index` (table) | ✅ | |
| `__index` (function) | ✅ | |
| `__newindex` (table or function) | ✅ | fires only for absent keys; `rawset` bypasses |
| `__call` | ✅ | walks chain; callee prepended to args |
| `__add` | ✅ | |
| `__sub` `__mul` `__div` `__mod` `__pow` `__unm` `__idiv` | ✅ | |
| `__band` `__bor` `__bxor` `__bnot` `__shl` `__shr` | ✅ | fired when operand is not integer-convertible |
| `__concat` | ✅ | |
| `__len` | ✅ | |
| `__eq` | ✅ | |
| `__lt` `__le` | ✅ | |
| `__tostring` | ✅ | `tostring`, `print`, and `string.format %s` all honour it |
| `__metatable` (protect metatable) | ✅ | `getmetatable` returns the value; `setmetatable` raises |
| `__pairs` | ❌ | |
| `__gc` | 🚫 | no finalizers on host GC |
| `__close` | 🟡 | natural block exit only; early exits (`return`/`break`/`goto`/error) not yet wired — see §3.3.2 |
| `__name` | ✅ | renames the type in `tostring` output and type-aware error messages |
| `__mode` (weak tables) | 🚫 | no weak refs in WasmGC today |

---

## 3.8 Garbage collection
Delegated to host GC. `collectgarbage(…)` is not implemented; reference
behaviour (incremental/generational, parameters, finalizers) is intentionally
out of scope — the host owns lifetime.

---

## 3.9 Coroutines
❌ Entire feature. Blocked on the WASM stack-switching proposal shipping in
browsers.

---

## Remaining gaps — concrete implementation list

Ordered by estimated effort (smallest first):

1. **`__pairs`** — the `pairs` builtin currently uses the raw next-based iteration; a `__pairs` lookup before falling through would be a small addition.
2. **`<close>` on early exits** — `__close` fires at natural block exit but not on `return`, `break`, `goto`, or error unwinds through an active close scope. Completing it needs an active-close-scope stack in codegen plus per-scope `try_table` unwinding — a milestone, not a small fix.
3. **`__gc`** — 🚫 not applicable; no finalizers in WasmGC.
4. **`__mode` (weak tables)** — 🚫 not applicable; no weak refs in WasmGC.
5. **Full `debug.*` library** — `debug.traceback` walks the frame stack (source positions only; no function names). `debug.getinfo` is unimplemented — its `nparams`/`nups`/`isvararg`/`linedefined` fields need per-function metadata that an AOT compiler without debug info doesn't retain.
6. **`load` / `loadfile`** — AOT-only; would need the compiler shipped at runtime. `require` works via `-m FILE` static modules.
7. **Coroutines** — blocked on the WASM stack-switching proposal shipping in browsers.
