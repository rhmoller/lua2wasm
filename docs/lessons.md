# Lessons learned & process notes

Living retrospective for lua2wasm milestone work. Updated after each
milestone closes. Items that have stopped being relevant get removed.

---

## What's working — keep doing

### Tiny commits, ctest between each, fixture per feature

Every feature lands in its own commit alongside its own e2e fixture.
When something breaks, `git bisect` is one step. The discipline of
*running the actual program*, copying its output, and using that as
the expected string has caught more bugs than the codegen has.

The 31-feature run from milestones 9 through 15 ended with a clean
linear history that reads top-to-bottom as "what was added when".
That's a reviewer's dream and worth preserving.

### Reproduce-in-test-first

Every bug fix during the mid-stream sweep landed alongside a failing
fixture in the same commit. The fixtures double as regression tests
forever. Six latent bugs caught (`%` `//` `^` `tonumber` `..` `< <= > >=`)
plus three cascade fixes (`print` of nil, `tostring` of tables,
pcall-inline-print). All would have eventually broken user programs.

### Host-side parsing for complex strings

`tonumber` and `string.format` both moved their parser to JS. The
WAT side just dispatches; JS does the regex / printf-style work it's
good at. WAT shrinks substantially, correctness improves, adding a
new format specifier costs one case in the JS dispatch.

Don't do this for hot-loop work. Do it where the WAT alternative is
hundreds of lines of byte-walking.

### Shared dispatch helpers in the prelude

`$arith_mm`, `$compare_mm`, `$utf8_decode_step`/`$utf8_assemble`,
`$str_case_map`. Each consolidated logic that would otherwise
duplicate per-op. Adding a new arithmetic metamethod is now five
lines of glue.

When the *third* function in a milestone wants the same boilerplate,
extract the helper before the third is written.

### Design doc before high-blast-radius work

Milestones 19 (`_G` reification) and 20 (patterns) both started with a
short `docs/design/<n>-*.md`. Both paid back the 30 min – 3 h cost in
avoided mid-PR rework: lockable invariants got named upfront, the risk
register surfaced the gotcha that would otherwise have bitten in
implementation. See the retros below for specifics.

Trigger to write one: the milestone either (a) touches a load-bearing
invariant ("globals live in per-name wasm slots"), or (b) introduces a
new internal contract that >3 prelude functions will share (capture
state shape, pattern bytecode). For purely additive milestones (a new
builtin, a new operator) the preflight checklist is enough.

### WASM-levers table from the implementation plan

Actually consulted. `array.copy` for string building; `i31ref` for
tagged ints; `try_table` + `throw $LuaError` for catchable errors;
`call_ref` for user callbacks (sort comparator, every metamethod
dispatch). The temptation to "just walk bytes in a buffer" doesn't
come up if the lever is right there.

---

## Recurring failure modes — watch for these

### WAT validator: "non-nullable local's sets must dominate gets"

Hit twice (`string.rep`, `table.move`). A non-nullable typed local
assigned only inside an `if` then read after — the validator can't
prove it was set.

```wat
;; BAD: validator error
(local $x (ref $T))
(if cond (then (local.set $x …)))
(local.get $x)

;; GOOD: unconditional default first
(local $x (ref $T))
(local.set $x default)
(if cond (then (local.set $x …)))
(local.get $x)
```

### Two embeddings of the same host imports

The Node runner (`runtime/host.mjs`) and the playground
(`runtime/playground.html`) used to maintain parallel host-import
blocks. Every new import landed on the Node side only; the playground
silently broke until someone tried it (symptom:
`WebAssembly.instantiate(): Import "host" "math2": function import
requires a callable`).

**Now:** pure-JS helpers live in `runtime/host-bindings.mjs`
(`makeHelpers({ getInstance, formatFloat, cFormatG })`); both runners import
from it and each contributes only its own print/write/read wiring
(sync stdin vs JSPI line prompt).

**Mitigation:** any new `host.*` import goes into the factory. The
Node test suite's clean pass tells you nothing about the playground
— smoke-test it manually after milestones that add host imports.

### Global-name collisions across builtin classes

A library entry whose Lua name matches a top-level builtin
(`type` ↔ `math.type`) generated the same wasm-global name. Caught
when adding `math.type`; fixed by switching to the unique WAT func
name. Future milestones must watch this for: `pairs`, `next`, `type`,
`pcall`, `assert`, `select`, `error`, `tostring`, `tonumber` — any
top-level that a library might want to mirror.

### `i32.and` is not short-circuiting

Bit twice in milestone 20 (`$match_set` range guard, `?`-quantifier
sub-read). `(i32.and A B)` evaluates *both* operands unconditionally,
so if `B` does e.g. `(array.get_u $LuaStringBytes …)` with an index
that's only valid when `A` is true, you get an OOB trap, not a `false`.

```wat
;; BAD: array.get_u runs even when spos >= len
(i32.and
  (i32.lt_u (local.get $spos) (local.get $len))
  (i32.eq (array.get_u $bytes (local.get $buf) (local.get $spos))
          (i32.const 0x2D)))

;; GOOD: gate with if/then/else (or select with a safe default)
(if (result i32)
  (i32.lt_u (local.get $spos) (local.get $len))
  (then (i32.eq (array.get_u $bytes (local.get $buf) (local.get $spos))
                (i32.const 0x2D)))
  (else (i32.const 0)))
```

**Look-here-first instinct:** when a prelude helper traps on a boundary
input but the logic *reads* correct, suspect this before reading deeper.

### Cascade fixes when fixing a fundamental

A correctness fix in a primitive op (`..`, `==`, `<`) often exposes
2–3 more bugs in callers that quietly relied on the old behaviour.
The `..` type-check fix cascaded into `print` (used `$lua_concat`
directly with nil) and `$lua_tostring` (trapped on tables/functions).

**Rule:** when you touch a primitive op, immediately grep every caller
in the prelude and the codegen output for assumptions the old
behaviour was hiding. Don't ship the fix without auditing.

### Trailing whitespace in test EXPECTED literals

Some editors (and my own Write tool through certain paths) strip
trailing whitespace on save, which silently breaks fixtures whose
output legitimately ends a line with spaces. The `long_brackets`
fixture hit this — `[[ plain ]]` produces ` plain ` (space-plain-space)
on a line.

**Mitigations:**
- Use `$'...'` shell-quoted form for EXPECTED (preserves bytes more
  reliably than `"..."` through some tooling).
- Or build EXPECTED with `printf` from explicit hex escapes.
- When `diff` reports a 1-character mismatch on a string that should
  match, immediately `cat -A` both sides to expose invisible
  whitespace.

### Hand-authored expected output

Two self-correction commits (`string_rep` blank-line count,
`string_format` exponent format). The fix is mechanical: always
copy-paste the actual `node host.mjs … wasm` output, never hand-write
the expected string. The expected output is what the program produces;
the *fixture comments* are where you encode intent.

### Docs go stale faster than features ship

Milestone 16's preflight expected to add `\xHH`, `\u{…}`, `\ddd`, `\z`
because docs/language-features.md listed them as missing. They were
all already implemented; only `\<line-break>` was actually missing.
Same with hex literals — listed twice in the README's "Not yet"
column, but the docs.md only ever called out the lexer-side gap.

**Mitigation:** before starting a milestone, run the existing
implementation against fixtures derived from the manual examples,
not against the stale doc claims. The compiler is the source of
truth for what's currently supported; the doc is just a label.

### Hand-counting parens in WAT

The `$lua_tostring` extension produced "Unexpected tokens after
module" because of one extra `))` after a multi-branch nested
`if/then/else`. Hit it AGAIN on the `$match_class` chained
else-if (10 levels deep), surfacing as "unrecognized module field"
in `wasm-as` because the extra close ended the module early.

**Mitigations:**

- Prefer `(return …)` early in each branch over nested `if … else`
  with a shared result expression. Flatter structure, easier to
  count.
- WAT comments containing `(` or `)` can confuse external paren
  counters. Use plain prose: `;; takes an optional second arg` not
  `;; takes an optional second arg (in the args array)`.
- For chained `else-if` past ~5 levels: count nesting explicitly
  before writing the closing tail. Each `(else (if …))` adds 2
  closing parens; an N-way dispatch with a final `else` needs
  `1 + 2*(N-1)` trailing closes. Always verify by running the
  per-line-depth awk:

  ```sh
  awk '/^  \(func \$NAME/,/^  \(func \$NEXT/' prelude.wat \
    | awk '{for(i=1;i<=length;i++){c=substr($0,i,1);if(c=="(")d++;else if(c==")")d--}print d,$0}'
  ```

  A negative number at any line is your miscount.

### Behavioural-vs-formatting mismatches in the host

Float formatting between Lua's `%g`/`%.14g` and JS's `toPrecision`
disagree on edge cases (trailing-zero stripping, scientific vs
decimal transition). Hit twice (`bisect` sample, `1.2e+4` vs
`1.2e+04`). When a fixture starts matching only "after some
substring", treat that as a signal that the formatter — not the
computation — is the variable.

**Mitigation:** `runtime/format.mjs` is the canonical float
formatter. Both `runtime/host.mjs` and `runtime/playground.html`
import `formatFloat` / `formatScalar` from it — no duplicates. Never
reach for `Number.prototype.toString` / `toPrecision` directly in
WAT-adjacent JS; extend `format.mjs` instead so both runners stay
in lockstep.

---

## Per-milestone preflight (10 minutes, before the first commit)

Before opening the prelude for a new milestone, jot down:

1. **Manual edge cases.** What does the manual explicitly call out as
   non-obvious? "Returns nil if X." "Errors if Y." "Different default
   when N is negative." Most surprises live here.

2. **Existing helpers to reuse.** Skim the prelude index of helpers.
   `$arith_mm`, `$compare_mm`, `$utf8_decode_step`, `$tab_get_raw`,
   `$lua_call`, `$args_first`, `$make_int`, `$make_float`, `$lua_truthy`,
   `$is_int`, `$is_float`, `$as_int`, `$as_float`. Most milestones
   reuse 3–5 of these.

3. **WASM levers.** What's the right primitive? `array.copy`?
   `call_ref`? `try_table`? `array.new_data` from a strpool slot?
   `i31ref` for small ints? Pick deliberately.

4. **Integration points.** Which files? `runtime/prelude.wat` always;
   `src/builtins.c` (registration); `runtime/host.mjs` (if a host
   helper); `src/codegen.c` (if a new global or pre-declared name);
   `src/parser.c` (if a new implicit global like `utf8`).

5. **Name-clash check.** New library entry whose Lua name matches an
   existing top-level builtin? Add a TODO to the preflight.

6. **Fixture sketch.** What .lua program exercises the golden path
   AND the documented edge cases? If you can list 6–10 print outputs
   you're confident about, the work is well-scoped. If you can't,
   keep reading the manual.

---

## Design-doc retros

### When the design doc actually paid off (milestone 19, `_G`)

The pre-coding `docs/design/19-global-env.md` was worth the 30 minutes.
It forced answers to questions that would have been expensive to
discover mid-implementation:

- *What's the storage model?* Is `_G` a proxy, a shadow, or the source
  of truth? The Lua spec answers "source of truth" — the doc made me
  commit to Plan A before I started typing.
- *What about the existing per-builtin wasm globals?* The doc clarified
  they stay (internal prelude code references them) but are no longer
  user-reachable. User reads/writes go to `$g_globals` only.
- *Are builtin reassignments legal?* Yes per spec — but the parser
  rejected them. Spotted during the doc, fixed in the parser changes.
- *Performance impact?* One hash lookup per global access instead of
  one wasm-global load. The doc noted that reference Lua does exactly
  the same thing, so we're not regressing relative to it.

Code-change count came out close to the doc's "five steps". No
surprise mid-PR fixes; implementation was mostly mechanical
substitution. Compare to milestone 17's `goto` where I designed
mid-flight and hit the overlap edge case unprepared.

The pattern: when the existing codebase has a *load-bearing* invariant
that the milestone changes (here: globals live in per-name wasm slots),
a design pass that names both the invariant and its replacement is
high value. When the change is purely additive (new builtin, new
operator), the preflight checklist is sufficient.

### When the design doc held up (milestone 20, patterns)

`docs/design/20-lua-patterns.md` proposed a 9-step plan with a per-
step fixture. All 9 steps landed in 9 commits matching the plan;
step 7 caught the cross-cutting bug I'd already paid for once in
step 2 (the `i32.and`-is-not-short-circuit gotcha), exactly because
the fixture-per-step discipline surfaced it instead of letting it
cascade into step 8.

Cost: ~3 hours of writing the design before any code. Saved at
least that much by:

- Locking in the `(end_spos_or_-1, ncaps_out)` multi-value return
  shape upfront — the alternative (pack into i64, or smuggle ncaps
  via a side global) would have churned every call site.
- Knowing that captures NEST and the close-then-revert pattern was
  needed (the `saved = -1; recurse; if fail, restore` trick in the
  `)` case). Caught during design; would have been a confusing
  multi-hour bug otherwise.
- Knowing that quantifiers apply ONLY to a single char-class —
  ruled out a whole class of "capture-with-quantifier" backtracking
  complexity that doesn't exist in Lua.
- The risk register's "first-time-closure-with-upvalues-from-a-
  builtin" call-out made step 6 a smooth one-shot — the existing
  `$LuaClosure` + `$UpvalArr` shape handled it without any new types.

Surprises during implementation (additions to the lessons later):
1. `i32.and`-is-not-short-circuit bit me TWICE: once in step 2's
   set-range guard, once in step 7's `?`-quantifier sub-read.
   Each cost ~10 minutes — would have been more without the
   "look here first" instinct now baked in.
2. The `%b''` (same open/close) edge case isn't well-defined in
   Lua's spec ("x and y are two distinct characters"). My
   implementation silently fails to match; tests now skip the case
   entirely.
3. gsub with function repl + method-call syntax (`c:upper()`)
   doesn't work because we don't set up a metatable for strings
   yet. Documented as a separate gap, not a pattern bug.

### When the design doc held up (milestone 21, string.pack)

`docs/design/21-string-pack.md` proposed a 9-step plan and locked in
three load-bearing decisions before any WAT was written:

- Native sizes fixed once (`h=2`, `i/I=4`, `l/j/T=8`, `f=4`, `d/n=8`),
  documented in the doc itself.
- `pack` writes through a `$Builder` (grow on demand); `unpack`
  pre-counts options to allocate one `$ArgArr` of `(N + 1)`. No
  growing on the unpack path.
- No bytecode compilation of the format string — interpret each call,
  per the m20 lesson that "don't pre-compile the cheap case".

The 9-step plan compressed to 6 commits in practice: steps 4 (endian)
and 5 (alignment/`x`/`Xop`) were already operational in step 2's
walker, so they folded into the float commit's message. Otherwise
every step landed in one commit with its own e2e fixture and a green
ctest before the next started.

The oracle pattern from m20 paid off again: every numeric assertion
in every fixture was diff'd against `lua5.5` on the same Lua source.
One mismatch surfaced during step 1 (`c0` allowed in reference Lua,
rejected by our impl) — caught before the test landed. None of the
risk-register items bit during implementation.

The cost: ~3 hours design, ~6 commits implementation. The single
biggest unforced error was the `c0` semantics, which the doc would
have caught if I'd thought harder about "n=0 corner" upfront. Logged.

### Latent bug surfaced (hex literal wrap)

While probing during step 2, I noticed `0xfedcba9876543210` evaluates
to `0x7fffffffffffffff` in our compiler — the lexer clamps hex
literals with the top bit set to `i64.max` instead of wrapping per
the Lua spec. The pack fixture sidesteps the issue by using values
in the signed-i64 range; the real fix belongs in `src/lexer.c`'s
numeral parser. Not addressed in m21; logged as a follow-up.

## When to write a full design doc

Most milestones (raw* primitives, table fillers, math fillers, utf8
ops, metamethods) are well-covered by the manual + a preflight.
A dedicated `docs/design/<milestone>.md` *before* coding is needed
for:

- ~~**Milestone 20 — Lua patterns.**~~ Shipped. The design doc held
  up; retro is above.

- ~~**Milestone 21 — string.pack/unpack/packsize.**~~ Shipped. The
  design doc held up; retro above.

- ~~**Milestone 19 — `_G`, xpcall, error-with-level, warn.**~~ Shipped.
  The design doc held up; retro above.

- **Milestone 27 — coroutines.** Blocked anyway. When unblocked: state
  machine, scheduling, `__close` interaction, JSPI relationship.

The design doc answers: what's the on-disk representation? what are
the public functions and their preconditions? what existing prelude
helpers extend or wrap? what new helpers? any new host imports?
which test fixtures *must* exist before implementation starts?

---

## Bug-fix sweeps are high-density

The mid-stream sweep found six issues that would otherwise have
silently broken user programs. Repeat the sweep periodically — maybe
every 3–4 feature milestones — with a probe fixture exercising:

- All arithmetic ops on int/int, int/float, float/float, negatives, zero
- All comparison ops on int/string, cross-type, nil
- `concat` of every value kind including nil, table, function
- `tostring` of every value kind
- `print` of multiple args including nil, table, function
- `tonumber` of valid forms, garbage, mixed-type
- pcall around each of the above

If anything traps uncatchably or returns a placeholder, that's the
sweep's payoff. Even one fix per sweep justifies running it.
