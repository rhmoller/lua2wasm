# 22 — Maybe-typed numeric locals

Status: implemented (2026-09). Gated by the default optimization level; `-O0`
emits none of this and stays behaviour-identical (shared goldens).

## Problem

The int/float specialization (README "Performance") unboxes a local only when
*every* assignment to it is provably int or provably float. A value loaded
from a table field or array slot, or returned by a call, is an opaque
`anyref`, so any local fed from one stays boxed, and every arithmetic op or
comparison downstream is a generic runtime call plus a fresh `$LuaFloat` per
float result. In realistic code that is most arithmetic: nbody's inner loop
has zero unboxed ops (`bix - bj.x`), fannkuch's `q1 >= 4` goes through
generic compare and truthiness because `q1` came from `p[1]`. Profiles after
the string-key work put this at ~30% of nbody and fannkuch and ~15% of oo.

An AOT compiler cannot deoptimize, so it cannot *assume* a field holds a
float. It can speculate with a guard and keep a full-fidelity fallback.

## Representation

A **maybe-typed slot** `s` is a local the analysis marks as *probably
numeric*. It is emitted as four wasm locals:

| local | type | meaning |
|-------|------|---------|
| `$Lt<s>` | i32 | tag: 0 = boxed, 1 = int, 2 = float |
| `$Li<s>` | i64 | the value when tag == 1 |
| `$Lf<s>` | f64 | the value when tag == 2 |
| `$L<s>`  | anyref | the value when tag == 0 (anything: string, table, nil, …) |

Only the field selected by the tag is meaningful. Tag 0 is the complete
fallback: a maybe slot can hold *any* Lua value, so the representation never
changes semantics, only which code path computes them.

Expression temporaries use the same shape (`$mt<k>`, `$mi<k>`, `$mf<k>`,
`$mg<k>` for box/int/float/tag), allocated per function from a depth counter
sized by a pre-pass over the body's expression trees.

## Analysis

Per function, after the int and float slot analyses and with the same
optimistic-then-kill fixpoint shape (`maybe_kill_stmt`). A slot is a
candidate iff it is not captured (captured locals live in a `$Box`), not a
parameter (v1), not int- or float-typed already, and not `<close>`. It is
killed if any assignment is not *numeric-plausible*, where plausible means:
an int/float literal, any variable read, a call or method call, an index, an
arithmetic/bitwise binop, `and`/`or` (the `t.n or 0` idiom), unary minus /
length / bitwise-not, or `...`. Constants of other types, concatenation,
comparisons, `not`, table constructors and function expressions kill the
slot. Names past the value list, names fed from a multi-value tail, generic-
`for` variables, numeric-`for` control variables and `local function` slots
are killed too — their stores go through paths this design leaves alone.

A candidate must also be **used numerically** at least once: it appears, as
a direct read, somewhere inside an arithmetic, comparison or unary-minus
tree. Otherwise the classification on store is pure overhead and the slot
stays a plain `anyref`.

## Emission

**Store** to a maybe slot from expression `e`:

- `e` provably int → set `$Li`, tag 1; provably float → set `$Lf`, tag 2.
- `e` is a lowered arithmetic tree (below) → lowered straight into the slot.
- otherwise → `$L = e`, then `$unbox_num` (prelude) classifies once:
  `(call $unbox_num v)` returns `(tag, i64, f64)` from a `ref.test` chain
  over `i31` / `$LuaInt` / `$LuaFloat`.

**Read** in a boxed context → `(call $box_num tag i f b)`: `make_int` /
`make_float` / the anyref, so allocation happens only at real `anyref`
boundaries (table stores, call arguments, returns, concatenation).

**Arithmetic trees.** A binop `+ - * / // %`, a comparison, or a unary minus
whose subtree (through such nodes) reads at least one maybe slot is
*lowered*: operands are evaluated left to right into temporaries (order and
side effects exactly as Lua), then a tag switch computes the result:

```
both tags 1            : i64 op (wraps mod 2^64 like Lua); `/` converts both
                         to f64; `//` `%` use $idiv_floor / $imod_floor
both tags nonzero,
  at least one float,
  op in + - * /        : f64 op after f64.convert_i64_s on the int side
anything else          : the generic runtime helper on the boxed operands,
                         result tag 0 (metamethods, string coercion, errors
                         — identical to today's path)
```

Comparisons produce a raw `i32` in condition context (`if`/`while`/`repeat`)
and a Lua boolean in value context. Same-tag int or float compares inline;
mixed int/float goes generic because Lua compares those exactly. `^`, the
bitwise ops and `..` are never lowered.

In a boxed context the whole lowering is wrapped in `(block (result anyref)
… (call $box_num …))`, so it composes with any surrounding expression.

## Invariants

- The int/float lattice rule stands: int and float are incomparable and
  never merged; a mixed op yields a float only where Lua does.
- The tag-0 path is the pre-existing generic path with the same operands,
  so error text, metamethod dispatch and coercions are unchanged.
- `expr_is_int` / `expr_is_float` are false for maybe reads: nothing else in
  the specializer treats a maybe slot as proven.
- `-O0` never marks a slot maybe; e2e goldens are shared across levels.

## Risks and what guards them

- **Evaluation order.** Operands are always materialized into temporaries
  before the tag switch; the switch itself has no side effects.
- **Temporary clobbering.** Nested lowerings (an opaque operand that itself
  contains a lowered tree) allocate above the current depth; a pre-pass
  over-approximates the deepest need.
- **Wrong speculation.** Only costs time (classification + a fallback call),
  never correctness — `tests/fixtures/maybe_typed.lua` exercises slots that
  turn out to be strings, tables with metamethods, nil, and that change type
  mid-function, against a lua5.5-captured golden, at both `-O1` and `-O0`.
- **Fuzzing.** `scripts/diff-fuzz.mjs --phase numeric` and `--phase tables`
  generate exactly this shape (values through tables into arithmetic).

## Not in v1

Parameters (classify at entry), generic-`for` variables, typed direct-call
arguments from maybe slots, `//` `%` on floats, and a parallel `f64` value
array in `$LuaTable` so float fields never box on store.
