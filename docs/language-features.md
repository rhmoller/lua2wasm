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
| Long comment `--[=[ … ]=]`, `--[==[ … ]==]` (level N) | ❌ | lexer only knows level 0 |

### Numeric literals
| Form | Status | Notes |
|---|---|---|
| Decimal int `123` | ✅ | |
| Decimal float `3.14` | ✅ | |
| Exponent `1e10`, `2.5E-3` | ✅ | |
| Hex int `0xFF`, `0Xff` | ❌ | lexer treats `0` as int, then `xFF` as identifier |
| Hex float `0x1.8p3`, `0x1p-4` | ❌ | |
| Numeric underscores (not Lua std) | 🚫 | not in Lua 5.5 |

### String literals
| Form | Status | Notes |
|---|---|---|
| Short `"…"` and `'…'` | ✅ | |
| Escapes `\n \t \\ \" \' \0 \a \b \f \r \v` | ✅ | |
| `\xHH` (2 hex digits) | ✅ | |
| `\u{H…}` (UTF-8, up to 6-byte form ≤ 0x7FFFFFFF) | ✅ | matches reference Lua's accepted range |
| `\ddd` (1–3 decimal digits) | ❌ | |
| `\z` (skip following whitespace, incl. newlines) | ❌ | |
| `\<newline>` → literal `\n` | ❌ | |
| Long bracket `[[ … ]]`, leading newline stripped | ✅ | |
| Long bracket level N `[=[ … ]=]`, `[==[ … ]==]` | ❌ | |

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
`integer`/`float` distinction: ❌ (not yet exposed; representation already
distinguishes).

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
| Attribute `local x <const> = …` | ❌ | parser sees `<` as `LT` |
| Attribute `local x <close> = …` | ❌ | no to-be-closed semantics |
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
| `goto label` / `::label::` | ❌ |

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
| `%` (modulo) | 🟡 | integer only; float `%` currently returns 0 |
| `^` (exponent, always float) | ✅ | |
| Unary `-` | ✅ | |
| `__add` / `__sub` / `__mul` / `__div` / `__mod` / `__pow` / `__unm` / `__idiv` metamethods | 🟡 | only `__add` |

### 3.4.2 Bitwise operators
| Op | Status |
|---|---|
| `&` `\|` `~` (xor) `<<` `>>` (binary) | ❌ |
| Unary `~` (bnot) | ❌ |
| `__band/__bor/__bxor/__bnot/__shl/__shr` metamethods | ❌ |

Lexer reserves the tokens; parser has no production for them yet.

### 3.4.3 Coercions and conversions
| Item | Status |
|---|---|
| Int↔float promotion in arithmetic | ✅ |
| String→number coercion in arithmetic (e.g. `"3" + 1`) | ❌ |
| Number→string coercion in `..` | ✅ |
| Integer-valued float comparison rules | ✅ |

### 3.4.4 Relational operators
| Op | Status | Notes |
|---|---|---|
| `==` `~=` | ✅ | structural for strings; reference equality for tables/functions |
| `<` `<=` `>` `>=` | ✅ | numbers and strings |
| `__eq` metamethod | ✅ | |
| `__lt` / `__le` metamethods | ❌ | |

### 3.4.5 Logical operators
| Op | Status |
|---|---|
| `and` (short-circuit) | ✅ |
| `or` (short-circuit) | ✅ |
| `not` | ✅ |

### 3.4.6 String concatenation
| Item | Status |
|---|---|
| `..` (right-associative) | ✅ |
| Number→string coercion via `..` | ✅ |
| `__concat` metamethod | ❌ |

### 3.4.7 Length operator
| Item | Status |
|---|---|
| `#s` for strings (byte length) | ✅ |
| `#t` for tables (border) | ✅ |
| `__len` metamethod | ❌ |

### 3.4.8 Precedence
Matches Lua 5.5 precedence table for all operators that are implemented.
Bitwise operators not yet slotted into the precedence climb.

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
| Form | Status |
|---|---|
| `f(args)` | ✅ |
| `f"string"` (paren-less single string arg) | ✅ |
| `f{table}` (paren-less single table arg) | ✅ |
| `obj:method(args)` | ✅ |
| `__call` metamethod | ❌ |

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
| `error(v)` raise | ✅ | no level annotation |
| `error(v, level)` | ❌ | |
| `pcall(f, …)` → `(ok, …)` | ✅ | |
| `xpcall(f, msgh, …)` | ❌ | |
| `assert(v[, msg])` | ✅ | |
| Stack tracebacks | ❌ | |
| Underlying mechanism | — | WASM `throw $LuaError` + `try_table` |

---

## 3.7 Metatables and metamethods

| Metamethod | Status |
|---|---|
| `__index` (table) | ✅ |
| `__index` (function) | ✅ |
| `__newindex` (table or function) | ❌ |
| `__call` | ❌ |
| `__add` | ✅ |
| `__sub` `__mul` `__div` `__mod` `__pow` `__unm` `__idiv` | ❌ |
| `__band` `__bor` `__bxor` `__bnot` `__shl` `__shr` | ❌ |
| `__concat` | ❌ |
| `__len` | ❌ |
| `__eq` | ✅ |
| `__lt` `__le` | ❌ |
| `__tostring` | ❌ |
| `__metatable` (protect metatable) | ❌ |
| `__pairs` | ❌ |
| `__gc` | 🚫 (no finalizers on host GC) |
| `__close` | ❌ (depends on `<close>`) |
| `__name` | ❌ |
| `__mode` (weak tables) | 🚫 (no weak refs in WasmGC today) |

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

## Syntax gaps — concrete implementation list

Ordered by leverage (smallest first):

1. **Numeric literals**: hex `0x…`, hex-float `0x1.8p…`, `\ddd` and `\z` string escapes, level-N long brackets.
2. **`<const>` / `<close>` attributes** — parser needs to special-case `<` after `local` name list; runtime semantics for `<close>` needs `__close` and to-be-closed scope tracking.
3. **`goto` / `::label::`** — parser productions + a forward-fixup pass; codegen as WASM `br` to labelled block. Lua scoping rule: a goto cannot jump into the scope of a local.
4. **Bitwise operators** — six binary + one unary, plus six metamethods. Requires int-only semantics with float-with-integer-value coercion (Lua's "convertible to integer" rule).
5. **String→number coercion in arithmetic** (`"3" + 1` → `4`).
6. **Missing arithmetic metamethods** (`__sub/__mul/__div/__mod/__pow/__unm/__idiv`) and **`__concat`/`__len`/`__lt`/`__le`/`__newindex`/`__call`/`__tostring`** — each is a small addition to the existing metamethod dispatch in `prelude.wat`.
7. **`error(v, level)`** + **`xpcall(f, msgh, …)`** — wire a handler call into the `try_table` catch path.
