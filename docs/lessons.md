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

### Global-name collisions across builtin classes

A library entry whose Lua name matches a top-level builtin
(`type` ↔ `math.type`) generated the same wasm-global name. Caught
when adding `math.type`; fixed by switching to the unique WAT func
name. Future milestones must watch this for: `pairs`, `next`, `type`,
`pcall`, `assert`, `select`, `error`, `tostring`, `tonumber` — any
top-level that a library might want to mirror.

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
`if/then/else`. Two mitigations:

- Prefer `(return …)` early in each branch over nested `if … else`
  with a shared result expression. Flatter structure, easier to
  count.
- WAT comments containing `(` or `)` can confuse external paren
  counters. Use plain prose: `;; takes an optional second arg` not
  `;; takes an optional second arg (in the args array)`.

### Behavioural-vs-formatting mismatches in the host

Float formatting between Lua's `%g`/`%.14g` and JS's `toPrecision`
disagree on edge cases (trailing-zero stripping, scientific vs
decimal transition). Hit twice (`bisect` sample, `1.2e+4` vs
`1.2e+04`). When a fixture starts matching only "after some
substring", treat that as a signal that the formatter — not the
computation — is the variable.

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

## When to write a full design doc

Most milestones (raw* primitives, table fillers, math fillers, utf8
ops, metamethods) are well-covered by the manual + a preflight.
A dedicated `docs/design/<milestone>.md` *before* coding is needed
for:

- **Milestone 20 — Lua patterns.** ~400 reference lines; class
  matching, captures, anchors, back-references, balanced match,
  frontier match, gsub replacement modes (string/table/function).
  Without a design, expect 2x effort and rework.

- **Milestone 21 — string.pack/unpack/packsize.** ~500 reference
  lines. Format directives, alignment, endianness, length-prefixed
  strings. Similar risk profile.

- **Milestone 19 — `_G`, xpcall, error-with-level, warn.**
  Reifying globals as a real table has large blast radius — every
  global read/write becomes a table access. The design must answer:
  do compile-time-known globals stay in fast-path wasm globals while
  `_G.foo` is the runtime path? How are they kept in sync?

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
