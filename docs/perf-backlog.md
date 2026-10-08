# Performance backlog

The remaining bottlenecks, ranked by expected payoff, with the evidence and a
fix sketch for each. Snapshot of 2026-10-08 (after the run-once loop work,
[design note 24](design/24-run-once-loops.md)). Update it when an item lands
or a measurement changes.

## Where we stand

Seconds (`TIME`, best of five) on one machine, Node 24:

| bench | lua5.5 | lua2wasm | ratio |
|---|---:|---:|---:|
| binarytrees | 0.36 | 0.17 | 0.46× |
| fannkuch | 0.83 | 0.45 | 0.55× |
| oo | 0.46 | 0.28 | 0.60× |
| spectralnorm | 0.89 | 0.54 | 0.61× |
| vectors | 1.07 | 0.76 | 0.71× |
| nbody | 0.44 | 0.36 | 0.80× |
| entities | 0.68 | 0.58 | 0.85× |
| nbody_arr | 0.38 | 0.35 | 0.92× |
| tilemap | 0.29 | 0.29 | 1.00× |
| particles | 0.59 | 0.68 | 1.15× |
| closures | 0.08 | 0.09 | 1.20× |
| hashtab | 0.10 | 0.15 | 1.51× |
| strings | 0.07 | 0.17 | 2.49× |

## Measuring

- `scripts/bench.sh [name...]` — the suite (`RUNS=5` keeps the best run).
  `TIME` is `os.clock()`, the process's CPU time, which **includes V8's
  background compiler and parallel GC threads**; reference Lua is
  single-threaded. When `TIME` and wall time disagree, compare with node's
  `--single-threaded-gc` (strings: `TIME` 199 → 159 ms, same wall time).
- `scripts/profile.sh FILE.lua [N]` — self time by wasm function (needs
  Binaryen's `wasm-as` for the name section). `TREE=1` adds the call tree;
  `INLINING=fn` lists V8's inlining decisions while optimizing `$fn`, with
  names.
- `scripts/micro.sh bench/micro/X.lua` — a microbenchmark under `lua5.5` and
  lua2wasm, side by side:
  - `ops.lua`: per-operation costs on optimized code (third run timed);
  - `iter.lua`: ipairs / pairs / closure iterators against a numeric for;
  - `strings_sections.lua`: bench/strings.lua's sections, cold;
  - `strings_warm.lua`: the same sections, first run against warmed up.
- Compiler switches: `-O0` (boxed fallback), `--loop-chunk=0` (no loop
  outlining). `L2W_FLAGS` passes them through bench.sh, micro.sh, profile.sh,
  diff-test.sh and diff-fuzz.mjs.
- V8 flags that answer "what is X worth": `--wasm-inlining-budget=50000`
  (helpers inlined everywhere), `--min-semi-space-size=64` (GC heap growth
  removed), `--wasm-tiering-budget=N` (earlier tier-up), `--trace-gc`.
- `grep` on the dev machine is ugrep: a `$` inside a pattern is an anchor, so
  use `grep -F` for WAT names like `$ol_2`.

## Backlog

### 1. Hot helpers aren't inlined into big functions

**Evidence.** particles spends 58% of its time in three integer-key table
helpers — `$lua_index_ik_cell` 35%, `$lua_tabset_ik_f` 18%,
`$lua_index_mk_cell` 5% — all called from `$ol_2`, the outlined frame loop.
`INLINING=ol_2 scripts/profile.sh bench/particles.lua` shows "not enough
inlining budget" on every one of them: V8 caps a function's size after
inlining at about 5000 (`--wasm-inlining-budget`) and at 3× its own size
(`--wasm-inlining-factor`), and `$ol_2` is already 5049 bytes, so it gets
about 500. With `--wasm-inlining-budget=50000` particles takes 600 ms instead
of 693 (−13%); the other benchmarks don't move. That is a lower bound: an
inline fast path also saves the call.

**Fix.** Emit the array fast path at each integer-key site and call the
helper only when it misses: a table without a metatable (or a read that hits
a non-nil slot), the key within `1..$alen`, `array.get`/`array.set` (plus the
`$g_fmark` marker / `$farr` check for unboxed floats). Sites: `emit_index_expr`
(expr.c, `$lua_index_ik`), `emit_maybe_lower` (maybe.c, `$lua_index_ik_cell`,
`$lua_index_mk_cell`), `emit_index_store_from` (stmt.c, `$lua_tabset_ik`,
`$lua_tabset_ik_f`); helpers in runtime/prelude/index.wat. Keep the semantics
of holes (a nil read falls through to `__index`), `__newindex` on absent keys
and the trailing-hole trim on nil stores. Alternatively, or as well, outline a
big outlined loop's own hot inner loops so each gets a budget of its own.

**Verify.** particles, nbody_arr, fannkuch, tilemap; watch module size.

### 2. Strings and big integers allocate too much

**Evidence.** GC is 29% of strings' profile and 18% of hashtab's. The cold
`build` section of strings (`parts[#parts + 1] = word .. n`, 200k times)
takes ~57 ms against 8 ms warm and 14 ms in lua5.5; with
`--min-semi-space-size=64` it takes 27 ms — it is GC-bound (young-generation
scavenges copying fresh strings that stay alive).

**Causes.**
- Every Lua string is two GC objects: the `$LuaString` struct and its
  `(array i8)`.
- Concatenating a number allocates its digits (`$int_to_bytes`) before the
  result.
- A string made at run time is hashed (FNV over its bytes) when first used as
  a key, and compared byte by byte with the stored key; reference Lua interns
  short strings and compares pointers.
- An integer from 2^30 up in a boxed place (a captured local, a table value)
  is a `$LuaInt` object: hashtab's `rnd()` keeps its seed in a captured local,
  so about half of its calls allocate.

**Fix ideas.** One object per string (the bytes array carrying the cached
hash in a 4-byte header); concatenation writing number digits straight into
the result; typed boxes for captured locals that only ever hold integers (the
maybe-typed slot analysis, extended to upvalues); possibly interning short
run-time strings.

**Verify.** strings, hashtab, tilemap, closures; the GC share in profiles.

### 3. Warm-up dominates short programs

**Evidence.** `scripts/micro.sh bench/micro/strings_warm.lua`: `build` 56 ms
on the first run, 8 ms warm; `string.format` 44 ms, 11 ms warm (lua5.5: 14
and 31). Lowering `--wasm-tiering-budget` doesn't help; a larger young
generation does — this is mostly item 2. A short benchmark's `TIME` also
carries V8's parallel GC threads (see Measuring).

**Fix.** Mostly item 2. Consider reporting wall time next to `TIME` in
bench.sh, so helper-thread CPU doesn't read as slowdown.

### 4. String method calls take the generic path

**Evidence.** `s:byte(i)`: 52 ms against 35 ms in lua5.5 (`ops.lua`, 2M
calls, warm); strings' `byte` section 11–14 ms against 3.3.

**Cause.** The method inline cache (`$MIC`) serves table receivers; a string
receiver goes through `$lua_index` → the string metatable → its `__index`
table → a hash lookup of the method name, on every call. Then the builtin's
fast entry is `$fast_adapter`, which packs the arguments into an `$ArgArr` and
unpacks a result array: two allocations per call.

**Fix.** Let the method cache handle string receivers (remember the string
metatable's `__index` table and the method's position; check the receiver is
a `$LuaString` and the metatable unchanged). Give the hot string builtins
(`byte`, `sub`, `len`, `find`, `char`, `upper`, `lower`, `rep`) real `$LuaFn1`
fast entries instead of `$fast_adapter` (closure globals are built in
`emit_builtin_globals`, module.c). Where: runtime/prelude/index.wat
(`$lua_method_ic`, `$lua_method_ic_miss`), runtime/prelude/string.wat.

### 5. gmatch iteration

**Evidence.** strings' `gmatch` section: 31 ms warm against 13.5 in lua5.5.

**Cause.** Each match: the generic for calls the iterator through
`$lua_call_any` with a fresh argument array and gets a result array back; the
match is a new two-object string; `freq[w]` hashes it and compares bytes.

**Fix.** A generic for with one loop variable could call through the fast
entry (`$lua_call1`), and gmatch's iterator could have one; plus item 2.

### 6. The hash part's layout

**Evidence.** hashtab: `$tab_index_lookup_h` 15%, `$tab_set_hash` and
`$tab_insert_*` ~14%, `$tab_index_rebuild` 5%.

**Cause.** An index of positions, a keys array and a values array: a lookup
is three dependent loads, and growing rebuilds the whole index.

**Fix.** A single node array (key, value, chain) as in reference Lua. Mind
the shapes design ([note 23](design/23-table-shapes.md)): a table's key layout
lives in its `$Shape`, shared between tables built alike.

### 7. Array append and `#t`

**Evidence.** `ops.lua`: `t[#t + 1] = i` 26 ms against 15 in lua5.5;
growing an array with `t[i] = i` 11.7 against 6.0. `$arr_append` is ~5% of
closures and tilemap.

**Cause.** `#t` goes through `$lua_len` (type dispatch, `__len` check) and
`$tab_len`; the store goes through `$lua_tabset_ik` → `$tab_set_arr` →
`$arr_append` (growth and demotion checks).

**Fix.** Recognize `t[#t + 1] = v` in codegen and emit one append helper; a
cheaper `#t` for tables without a metatable; revisit the growth policy.

### 8. What run-once loop outlining doesn't cover yet

- Loops in a callback that runs once (`pcall(function() ... end)`,
  `xpcall(main, handler)`, a function handed to a runner) and in a global
  `function main() ... end main()` aren't recognized; they stay on baseline
  code (2–5× slower than warm). Detection: `compute_run_once` in
  src/codegen/outline.c.
- Only the outermost loop suspends: an outer loop with few iterations around
  a long inner loop runs its first iterations unoptimized.
- ipairs and pairs call the iterator through the generic protocol (argument
  and result arrays per iteration): `ipairs` is 5× slower than a numeric for
  over the same table (`iter.lua`), though still faster than lua5.5.

## Done

Maybe-typed locals ([note 22](design/22-maybe-typed-locals.md)), table shapes
and inline caches ([note 23](design/23-table-shapes.md)), run-once loop
outlining ([note 24](design/24-run-once-loops.md)), the fast/slow helper splits
and what V8 inlines ([lessons](lessons.md)).
