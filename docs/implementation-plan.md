# Implementation Plan

Closes the gaps documented in [`language-features.md`](language-features.md)
and [`stdlib.md`](stdlib.md). Organized into milestones; each milestone is
shippable on its own and adds one or more e2e fixtures under
`tests/fixtures/`.

Guiding rules:

- **Each milestone ends with a green `ctest`.** Don't merge a half-finished
  feature. The existing milestone-fixture pattern continues.
- **Reproduce in a test before fixing.** New features land with a failing
  fixture in the same commit as the fix.
- **No README drift.** When a milestone closes, update the README capability
  table *in the same commit*.
- **Order = leverage first.** Cheap wins early, big-ticket items (patterns,
  pack/unpack) deferred behind their own design docs.
- **Preflight before code.** Spend 10 minutes per milestone on the
  checklist in [`lessons.md`](lessons.md) — manual edge cases, existing
  helpers, WASM levers, integration points, name-clash check, fixture
  sketch. Most cycles I've lost mid-milestone trace back to skipping
  this step.
- **Audit after fixing a fundamental.** When a fix lands in a primitive
  op (`..`, `==`, `<`, arithmetic, table-set), immediately grep every
  caller. Old assumptions usually hide elsewhere too. See the cascade
  notes in `lessons.md`.

Effort estimates: **S** = ½ day · **M** = 1–2 days · **L** = ≥ 3 days.

---

## Clean-room discipline (read before touching code)

This project is a **clean-room reimplementation** of Lua 5.5. That isn't a
slogan — it's a sourcing rule:

1. **Do not read reference Lua's C source while implementing a feature.**
   `lua-5.5.0/src/` is *off limits* as a source of code, algorithms,
   variable names, or structure. Treat it the way you would a competitor's
   proprietary source under a clean-room NDA: the people writing our
   implementation must not have read theirs.
2. **The manual is the only spec.** `lua-5.5.0/doc/manual.html` (§3 and §6)
   is the authoritative behavioural spec. If a corner is underspecified,
   write a fixture, decide our behaviour, and document it. Don't sneak a
   peek at `lstrlib.c` to "see what real Lua does".
3. **The reference interpreter is a black-box oracle, not a source.** It
   is fine — and encouraged — to *run* `lua` on a test input and compare
   our output, byte-for-byte. It is *not* fine to read its source to
   understand how it produced that output. If our output differs, debug
   from the manual, not from the C.
4. **No transliteration of structure either.** Don't port `luaO_str2num`
   into our prelude under a different name. Independent design — even if
   it ends up shaped similarly because the spec constrains it — is the
   bar.
5. **Third-party Lua code (test suites, example programs) is fair game as
   input.** Running `string.lua` from the Lua test suite through both
   interpreters to compare outputs is testing, not copying. Don't paste
   its expected-output tables in either — regenerate them.
6. **When in doubt, write it from the manual and a fixture, then diff
   behaviour against reference Lua.** If you find yourself wanting to
   "just check how they handle X", stop, write a fixture for X, and
   reason about it from the spec.

**Algorithmic notes elsewhere in this plan** (e.g. "xoshiro256\*\*",
"quicksort", "Lua patterns") name *public algorithms or behaviours*, never
reference-Lua code. Implementations of those algorithms must be written
from their public descriptions or from our own designs.

---

## Take advantage of WASM, don't fight it

The project's defining constraint is that the WASM type system *is* the
runtime. Every milestone below should make a deliberate choice about which
WASM feature carries the weight — not default to "loop over bytes in a
linear-memory buffer".

| Concern | Default lever |
|---|---|
| String content | `(array i8)`; build new strings with `array.new` + `array.copy`, *not* a manual byte-copy loop. |
| String constants in builtins (e.g. `utf8.charpattern`) | One data segment + `array.new_data`. |
| Variable-length results (e.g. `string.byte` multi-return, `utf8.codes` iterator state) | `$ArgArr` (the existing multi-return shape), not a packed buffer. |
| Numeric tagging | `i31ref` for the common case, boxed struct for overflow / float. Don't re-tag through linear memory. |
| Tables | `$LuaTable` struct; resizing = `array.new` + `array.copy` between GC arrays. |
| Closures / callbacks (e.g. `table.sort` comparator, `gsub` function repl) | `call_ref` through the existing `$LuaFn` typed reference. |
| Errors / non-local exits (e.g. `__close` unwind, `xpcall` handler) | `throw $LuaError` + `try_table`. Don't invent a parallel error channel. |
| Dynamic type tests (metamethod dispatch, `tostring` polymorphism) | `ref.test` / `ref.cast` on the type hierarchy, not a tag-word switch. |
| Tail-recursive helpers in the prelude | `return_call_ref`. |

When a milestone introduces a helper that contradicts the table above, the
PR description must justify why. "It was easier to write a byte loop" is
not a justification.

---

## Milestone 9 — "raw" primitives + table fillers (S) — ✅ done

**Goal:** make defensive Lua code stop crashing on missing globals.

| Item | Source |
|---|---|
| `rawequal(v1, v2)` | stdlib.md §6.1 |
| `rawget(t, k)` | §6.1 |
| `rawset(t, k, v)` | §6.1 |
| `rawlen(v)` | §6.1 |
| `table.pack(...)` | §6.6 |
| `table.move(a1, f, e, t [, a2])` | §6.6 |
| `table.create(nseq [, nrec])` | §6.6 |

**Touches:** `src/builtins.c` (registry), `runtime/prelude.wat` (one prelude
function per builtin; the existing table ops are already there to copy from).

**Fixture:** `tests/fixtures/milestone9_raw.lua` — exercise each.

**Done when:** all seven callable; `table.pack(1,2,3).n == 3`; `rawget`
bypasses `__index` provably (write a table with `__index` returning sentinel,
verify `rawget` returns `nil`).

---

## Milestone 10 — `string` byte-level fillers (S) — ✅ done

**Goal:** the half of `string.*` that doesn't need a pattern engine.

| Item |
|---|
| `string.upper(s)` (ASCII) |
| `string.lower(s)` (ASCII) |
| `string.rep(s, n [, sep])` |
| `string.reverse(s)` |
| `string.byte(s [, i [, j]])` (multi-return) |
| `string.char(...)` |

**Touches:** `runtime/prelude.wat` (new helpers operating on `$LuaString`'s
`(array i8)`), `src/builtins.c`.

**Fixture:** `tests/fixtures/milestone10_string_bytes.lua`.

**Done when:** `string.byte("abc", 1, 3)` returns three values; `string.rep("ab", 3, "-") == "ab-ab-ab"`.

---

## Milestone 11 — `math` fillers + PRNG (S→M) — ✅ done

**Goal:** close the math library except for the corners nobody uses.

| Item | Notes |
|---|---|
| `math.deg`, `math.rad` | trivial |
| `math.fmod(x, y)` | truncating modulo (different from `%`) |
| `math.modf(x)` | two returns |
| `math.tointeger(x)` | exact int conversion or `nil` |
| `math.type(x)` | `"integer"` / `"float"` / `nil` |
| `math.maxinteger`, `math.mininteger` | constants |
| `math.ult(m, n)` | unsigned compare |
| `math.atan(y, x)` | second arg |
| `math.log(x, base)` | second arg |
| `math.random([m [, n]])` | xoshiro256** seeded from constant by default |
| `math.randomseed([x [, y]])` | returns `(seed1, seed2)` |

**Touches:** prelude (new functions), one WASM global pair for PRNG state.

**Fixture:** `milestone11_math.lua`.

**Done when:** `math.type(1) == "integer"`, `math.type(1.0) == "float"`;
seeded `math.random()` reproducible across runs.

---

## Milestone 12 — `utf8` library (S) — ✅ done

> `utf8.codes` accepts the `lax` flag but does not yet honour it (carry-over).

**Goal:** full `utf8.*` module (~150 lines reference).

| Item |
|---|
| `utf8.char(...)` |
| `utf8.charpattern` (a string constant) |
| `utf8.codepoint(s [, i [, j [, lax]]])` |
| `utf8.codes(s [, lax])` |
| `utf8.len(s [, i [, j [, lax]]])` |
| `utf8.offset(s, n [, i])` |

**Touches:** `src/builtins.c` registers a new `BLT_LIB_UTF8`; prelude gains a
UTF-8 decode helper that everything else builds on.

**Fixture:** `milestone12_utf8.lua`.

---

## Milestone 13 — finish `string.format` + `io.read` formats (M) — ✅ done

**Goal:** stop being a "half-printf"; let programs read more than lines.

`string.format` additions:
- Width and flags: `%-10s`, `%05d`, `%+d`, `% d`, `%#x`.
- Missing specifiers: `%i %o %u %X %c %q %a %A`.

`io.read` additions:
- `"l"` (line, no `\n`) — already partially there; canonicalize.
- `"L"` (line with `\n`).
- `"a"` (read all).
- `"n"` (number).
- Integer `n` (n bytes).
- Multiple formats in one call returning multiple values.

**Touches:** mostly `runtime/host.mjs` for the JS side of `io.read`; prelude
for `string.format` parser.

**Fixture:** extend `string_format.lua` and `io_read.lua`.

---

## Milestone 14 — `table.sort` (M) — ✅ done

**Goal:** the last "obviously expected" missing `table.*` entry.

- In-place quicksort over the array part.
- Comparator: optional Lua function called through `call_ref`.
- Default comparator: `<` with type checks.
- Must not invoke comparator on equal positions (Lua spec).

**Touches:** prelude only.

**Fixture:** `milestone14_sort.lua`.

---

## Milestone 15 — Metamethod completeness (M) — ✅ done

**Goal:** raise the metatable from "demo" to "usable".

Add dispatch + tests for:

| Metamethod | Notes |
|---|---|
| `__sub` `__mul` `__div` `__mod` `__pow` `__unm` `__idiv` | clone of existing `__add` path |
| `__concat` | binary, called on either operand |
| `__len` | unary, called on tables (and any non-string) |
| `__lt` `__le` | called when both operands fail builtin compare |
| `__newindex` | (table or function), respect `rawset` to bypass |
| `__call` | invoke metatable's `__call` when value-not-function is called |
| `__tostring` | wire into `tostring` and `print` |
| `__metatable` | honour in `getmetatable`/`setmetatable` |

**Touches:** prelude dispatch helpers; codegen for call/concat/len/compare.

**Fixture:** `milestone15_metamethods.lua` — one small test per metamethod.

**Done when:** all eight metamethods round-trip through `pcall` correctly,
and `__newindex` correctly traps on missing keys but lets `rawset` through.

---

## Milestone 16 — Numeric-literal completeness (S) — ✅ done

> `\ddd` decimal escapes were already in the lexer; the milestone added hex
> int/float literals, `\<newline>` continuation, and level-N long brackets.

**Goal:** stop syntax-erroring on `0xff`.

Lexer additions:
- Hex int `0x[0-9a-fA-F]+`, including `0X`.
- Hex float `0x[0-9a-fA-F]+(.[0-9a-fA-F]+)?[pP][+-]?[0-9]+`.
- String escape `\ddd` (1–3 decimal digits).
- String escape `\z` (skip whitespace).
- String escape `\<newline>` → `\n`.
- Level-N long brackets `[=[…]=]` for both strings and comments.

**Touches:** `src/lexer.c` only.

**Fixture:** `milestone16_literals.lua`.

**Done when:** `0xff == 255` and `[==[ ]] ]==]` parses as a string with `]]`
in the middle.

---

## Milestone 17 — `goto` / `::label::` (M) — ✅ done

**Goal:** close the last common control-flow gap.

- Parser: `goto NAME`, `::NAME::`. Forward and backward refs allowed.
- Validation: a goto cannot jump *into* the scope of a local declared
  between the goto and its label. Reference Lua does this with a per-block
  pending-goto list.
- Codegen: each label becomes a `block` continuation; gotos become `br` to
  the enclosing labelled block.

**Touches:** parser (new AST node + per-block label table), codegen.

**Fixture:** `milestone17_goto.lua` — forward, backward, continue-emulation,
and the "jumps into local scope" error case.

---

## Milestone 18 — Bitwise operators (M) — ✅ done

**Goal:** integers actually behave like Lua 5.5 integers.

- Parser: precedence climb for `|` `~` (binary xor) `&` `<<` `>>` and unary
  `~`. Precedence per Lua spec: `or | xor | & | shift | concat | add …`.
- Codegen: int-only. A float operand is accepted iff its value is exactly
  representable as a signed 64-bit integer (the manual's "convertible to
  integer" rule from §3.4.3); otherwise raise. NaN and infinities → error.
- Metamethods: `__band` `__bor` `__bxor` `__bnot` `__shl` `__shr`.

**Touches:** parser, codegen, prelude (one helper per op).

**Fixture:** `milestone18_bitwise.lua`.

---

## Milestone 19 — `_G`, `xpcall`, `warn`, `error(msg, level)` (M) — ✅ done

> `error(msg, level)` accepts and validates `level` but does not yet prepend
> `"file:line: "` — that requires the line-info side band scheduled for
> milestone 22.

**Goal:** finish the small base-lib leftovers.

- **`_G`**: reify globals as a real `$LuaTable` exposed under the global
  name `_G`. Code generation for global read/write becomes a table access on
  `_G` (with a fast-path for the compile-time-known case to keep the size
  win). This is the design choice with the most blast radius — write a
  design note before implementing.
- **`xpcall(f, msgh, …)`**: `try_table` catch path additionally calls
  `msgh(err)` and uses its return value as the second return of `xpcall`.
- **`warn(msg1, …)`**: emit on stderr (Node) / `console.warn` (browser);
  honour `"@on"` / `"@off"` toggle.
- **`error(msg, level)`**: when `msg` is a string, prepend `"file:line: "`
  based on the `level` argument (1 = caller, 2 = caller's caller, …). Needs
  a debug-line-info side channel — see Milestone 22.

**Touches:** codegen (global access), prelude (xpcall, warn), parser (line
info already tracked).

**Fixture:** `milestone19_baselib_leftovers.lua`.

---

## Milestone 20 — Lua patterns (L) — ✅ done

**Goal:** `string.find`, `string.match`, `string.gmatch`, `string.gsub`.

Big enough to warrant its own design doc first — **written from the
manual's "Patterns" subsection alone**, not from `lstrlib.c`. Suggested
shape:

1. Decide compile-once vs interpret-each-call. A small bytecode (one byte
   per pattern token) is a clean WasmGC fit: emit it into an `(array i8)`,
   match it with a recursive WAT function. The alternative (walking the
   source pattern string each step) is simpler but slower for `gmatch` /
   `gsub` where the same pattern fires many times.
2. Matcher operates on the subject's `(array i8)` directly via
   `array.get_u`. Capture state is a small `(array i32)` of (start, len)
   pairs — no linear memory.
3. Captures: positional `()` and substring `( … )`. Pick our own ceiling
   (e.g. 32) and document it; the manual doesn't mandate one.
4. Anchors `^` `$`, repetition `* + - ?`, classes including `%a %d %s …`,
   sets `[a-z]`, escaped magic chars, back-references `%n`, balanced match
   `%bxy`, frontier `%f[set]`.
5. Build `find/match/gmatch/gsub` on top.
6. `gsub` replacement modes: string (with `%0..%9` interpolation), table
   (key = capture), function (called via `call_ref` with captures).

**Design discipline:** the only inputs while drafting the design note are
the manual and existing prelude conventions. No reference-source reads.

**Fixture:** `milestone20_patterns.lua`. Add ~50 small assertions covering
each class, anchor, and capture variant. Cross-check by *running* the
reference interpreter on the same fixture and comparing outputs (allowed:
oracle testing) — but write the assertions from first principles before
running the oracle, so the fixture itself isn't shaped by what reference
Lua happens to do.

**Done when:** the pattern fixture is green and the README's "more of
`string`" caveat is removed.

---

## Milestone 21 — `string.pack` / `string.unpack` / `string.packsize` (L) — ⏳ pending

**Goal:** binary serialization. ~500 lines reference.

Format characters: `< > = ! b B h H i[N] I[N] l L j J T f d n s[N] z x X c[N]`.

Touches prelude only.

Done as its own milestone because it shares essentially nothing with the
other string ops.

**Fixture:** `milestone21_pack.lua`.

---

## Milestone 22 — Error location prefixing + minimal `debug` (M) — ⏳ pending

**Goal:** when `error("oops")` fires, see `"file:line: oops"`.

- Codegen emits a parallel line-info table mapping each call site / error
  site to `(source_id, line)`.
- `error(msg, level)` walks the WASM call stack via a side-band frame
  counter (we already maintain enough invariants — the `try_table` payload
  can carry the originating frame's `(source_id, line)`).
- `debug.traceback([msg [, level]])`: walks the same side band.
- `debug.getmetatable` / `debug.setmetatable`: behave like the base library
  versions but ignore `__metatable`.

**Fixture:** `milestone22_error_locations.lua`.

---

## Milestone 23 — `<const>` and `<close>` attributes (M) — ⏳ pending

**Goal:** modern Lua local-attribute syntax.

- Parser: after a local name, accept `<const>` or `<close>`. Compile-time
  error on multiple/unknown attributes.
- `<const>`: codegen-level enforcement — assignment to a `<const>` local is
  a compile-time error.
- `<close>`: requires runtime support. When the local goes out of scope
  (normal exit, `break`, `return`, error), call its value's `__close(value,
  err_or_nil)`. The error path needs `try_table` to invoke pending closers
  during unwind.

**Touches:** parser, codegen (scope exit hooks), prelude (`__close` dispatch).

**Fixture:** `milestone23_attributes.lua`.

---

## Milestone 24 — `os.*` browser-friendly subset + `io.open` (M→L) — ⏳ pending

**Goal:** real I/O against a host capability layer.

Browser-friendly (do first):
- `os.clock()`, `os.time([t])`, `os.difftime(t2, t1)`.
- `os.date([format [, time]])` — formatting is pure; the time itself is a
  host import.
- `os.getenv(name)` — empty/nil in browser; populated in Node.

File I/O (do second, behind a feature flag in `host.mjs`):
- `io.open(filename [, mode])` returning a file handle with the standard
  methods (`read/write/lines/seek/setvbuf/close/flush`).
- `io.lines(filename, …)`, `io.input`, `io.output`, `io.close`, `io.type`.
- `io.stderr`, `io.stdin`, `io.stdout` as preconstructed handles.

Out of scope for now: `os.execute`, `os.remove`, `os.rename`, `os.setlocale`,
`os.popen`.

**Fixture:** `milestone24_io_os.lua` (Node-gated).

---

## Milestone 25 — Static `require` (M) — ⏳ pending

**Goal:** programs split across multiple files compile into one wasm.

- Compiler CLI accepts multiple input files; one is the entry, the rest are
  modules keyed by their path/name.
- `require("name")` resolves at compile time to a synthesized closure that
  runs the module body on first call and caches the result in a
  compile-generated `package.loaded` table.
- `package.preload` and `package.searchers` not implemented; document as
  out of scope unless `load` lands.

**Fixture:** `milestone25_require/` directory with two files.

---

## Milestone 26 — `load` / `loadfile` / `dofile` (L) — ⏳ pending

**Goal:** dynamic code loading.

Requires the compiler at runtime. The Emscripten playground already
demonstrates the mechanism — generalize: ship the compiler-wasm alongside
program-wasm and expose a host import that compiles a string to a callable
function reference.

Defer behind `--with-loader` until 24 and 25 settle.

---

## Milestone 27 — Coroutines (L, blocked) — ⛔ blocked (awaiting WASM stack-switching)

Blocked on the WASM stack-switching proposal shipping in browsers (Safari
position pending; Chrome flag-gated). When it ships:

- `coroutine.create/resume/yield/status/running/wrap/close/isyieldable`.
- Use `stack.switch` to keep multiple Lua call stacks alive on one wasm
  instance.
- `__close` chain runs on `coroutine.close`.

---

## Cross-cutting tasks (not milestones)

- **Pattern test corpus** (lands with milestone 20). Treat the reference
  interpreter at `~/code/3rdparty/lua/lua-5.5.0` strictly as a *black-box
  oracle*: write our own fixtures from the manual, then run them through
  reference `lua` only to capture expected stdout. Do **not** copy chunks
  out of reference Lua's test suite (`testes/strings.lua` etc.) — that's
  reference *code*, not just behaviour.
- **README drift gate.** Each milestone PR updates the capability table.
  Consider a simple test that diffs the README's table against a fixture
  list to keep them in lockstep.
- **Stdlib coverage badge.** A `tests/coverage_stdlib.lua` script that
  introspects which globals exist in the compiled program; fails CI if a
  closed milestone's API regresses to missing.

---

## Suggested ordering at a glance

```
Quick wins:        9 → 10 → 11 → 12 → 16    ✅ done
Polish / sharpen:  13 → 14 → 15 → 19        ✅ done
Big language gaps: 17 → 18 → 23             ✅ 17, 18 done · ⏳ 23 pending
Heavy stdlib:      20 → 21                  ✅ 20 done · ⏳ 21 pending
Host integration:  22 → 24 → 25 → 26        ⏳ all pending
Blocked:           27 (coroutines)          ⛔ awaiting stack switching
```

The remaining "Not yet" surface in the README:
`<const>/<close>` (23), `string.{pack,unpack,packsize}` (21), error-location
prefix + `debug.*` (22), `os.*` / `io.open` (24), `require` (25),
`load`/`loadfile`/`dofile` (26), coroutines (27).
