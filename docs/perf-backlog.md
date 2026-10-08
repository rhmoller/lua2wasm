# Performance backlog

The remaining bottlenecks, ranked by expected payoff, with the evidence and a
fix sketch for each; what has landed is under Done. Snapshot of 2026-10-08.
Update it when an item lands or a measurement changes.

## Where we stand

Seconds (`TIME`, best of five) on one machine, Node 24. `TIME` is
`os.clock()`, CPU time, which for lua2wasm includes V8's background compiler
and parallel GC threads; `wall` is the same run timed by the wall clock
(`LUA2WASM_CLOCK=wall`), the fairer comparison with single-threaded Lua:

| bench | lua5.5 | lua2wasm | ratio | wall | wall ratio |
|---|---:|---:|---:|---:|---:|
| binarytrees | 0.359 | 0.121 | 0.34× | 0.086 | 0.24× |
| fannkuch | 0.826 | 0.337 | 0.41× | 0.333 | 0.40× |
| spectralnorm | 0.952 | 0.528 | 0.55× | 0.523 | 0.55× |
| oo | 0.461 | 0.264 | 0.57× | 0.236 | 0.51× |
| nbody_arr | 0.383 | 0.238 | 0.62× | 0.232 | 0.61× |
| vectors | 1.078 | 0.680 | 0.63× | 0.599 | 0.56× |
| particles | 0.585 | 0.454 | 0.78× | 0.420 | 0.72× |
| nbody | 0.436 | 0.350 | 0.80× | 0.348 | 0.80× |
| entities | 0.678 | 0.554 | 0.82× | 0.502 | 0.74× |
| tilemap | 0.284 | 0.240 | 0.85× | 0.187 | 0.66× |
| closures | 0.074 | 0.091 | 1.23× | 0.060 | 0.81× |
| hashtab | 0.096 | 0.150 | 1.56× | 0.088 | 0.92× |
| strings | 0.067 | 0.160 | 2.39× | 0.093 | 1.39× |

## Measuring

- `scripts/bench.sh [name...]` — the suite (`RUNS=5` keeps the best run).
  `TIME` is `os.clock()`, the process's CPU time, which **includes V8's
  background compiler and parallel GC threads**; reference Lua is
  single-threaded. The `wall` column reruns lua2wasm with `os.clock()` as wall
  time (`LUA2WASM_CLOCK=wall`, honoured by runtime/host.mjs); on the short
  benchmarks the two differ by a third (strings 0.16 against 0.09).
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

### 2. Strings and big integers allocate too much

**Evidence.** GC is 29% of strings' profile and 18% of hashtab's. The cold
`build` section of strings (`parts[#parts + 1] = word .. n`, 200k times)
takes ~57 ms against 8 ms warm and 14 ms in lua5.5; with
`--min-semi-space-size=64` it takes 27 ms — it is GC-bound (young-generation
scavenges copying fresh strings that stay alive).

**Causes.**
- Every Lua string is two GC objects: the `$LuaString` struct and its
  `(array i8)`.
- A string made at run time is hashed (FNV over its bytes) when first used as
  a key, and compared byte by byte with the stored key; reference Lua interns
  short strings and compares pointers.
- An integer from 2^30 up in a boxed place other than a captured local (a
  table value, a maybe-typed cell boxed for a call) is a `$LuaInt` object.

**Fix ideas.** One object per string (the bytes array carrying the cached
hash in a 4-byte header); possibly interning short run-time strings.

**Verify.** strings, hashtab, tilemap, closures; the GC share in profiles.

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

**Inline array-part paths** (was item 1). V8 inlines callees into a function
only until it has grown by a budget (about 5000 wire bytes, and 1.1× its own
size past that), so a big function — particles' outlined frame loop, 5049
bytes — kept its hottest table reads as calls ("not enough inlining budget"
in `INLINING=ol_2`). Each integer-key read and write now probes the array part
inline — table test, `1..#array part`, a hole or non-float value to the
helper, `$g_fmark` → the f64 storage, a small int classified on the spot — and
calls the helper only on a miss (src/codegen/arrays.c). particles 0.68 →
0.46 s, fannkuch 0.45 → 0.34, nbody_arr 0.35 → 0.24, binarytrees 0.17 → 0.15;
more than `--wasm-inlining-budget=50000` gave (0.60 on particles). Modules
grow ~150 bytes per site (+1% over the e2e fixtures, +29% on nbody_arr);
dropping the inline small-int case costs fannkuch 6%.

**`..` writes integer digits in place** (item 2). `$concat_piece` /
`$concat_put` size an integer operand with `$int_len` and write it into the
result with `$int_write`, instead of allocating its digits first. strings
0.184 → 0.156 s.

**Int boxes** (item 2). A captured local that only ever holds integers lives
in an `$IBox` — a `$Box` subtype with a raw i64 — instead of a `$Box` holding
a `$LuaInt` from 2^30 up (analysis.c, "Int boxes": every store, in its own
function or a closure's, must be one int-typed value, under both parameter
seedings a body is emitted with). Signature inference reads the boxes, so a
function returning one returns an i64; the two alternate until the set
settles. 6M calls of hashtab's `rnd()`: 67 → 18 ms (lua5.5: 94). tilemap
0.28 → 0.26, hashtab 0.147 → 0.142.

**String methods and builtin fast entries** (was item 4). The method cache
takes string receivers: the string metatable and the string library play
the metatable and the class, and the entry has no receiver shape, so a table
never matches it. Builtins can have a `$LuaFn1` fast entry of their own
(`<name>_f`, listed in src/builtins.c) instead of `$fast_adapter`'s two
arrays per call: the string functions byte/sub/len/char/upper/lower/rep,
math floor/ceil/abs/sqrt/sin/cos/min/max, type, tostring, setmetatable and
table.insert's append. `s:byte(i)` 49.6 → 19.2 ms (lua5.5 32.6),
`setmetatable` 20 → 12, `math.max` 25 → 15. Fixed on the way: an explicit
nil optional argument is absent (`s:byte(nil)`, `s:sub(2, nil)`,
`s:rep(2, nil)`), positions past 2^31 clamp instead of wrapping, and
`table.insert(t, v)` honours `__len` / `__newindex`. `math.sin` stays at
34 ms against 24: the wasm→JS call dominates (importing `Math.sin` directly
saves 10–20%).

**List constructors in one array.** `{v1, ..., vn}` (positional values, no
multi-value tail) evaluates its values into one `array.new_fixed` that
becomes the array part (`$tab_new_arr`), instead of `$tab_set_ik` per value
through `$arr_append` / `$arr_ensure`. Those two also crowded `$tab_new` out
of V8's inlining budget in binarytrees' `BottomUpTree`, where the choice
then flipped with function indices (an unrelated prelude change cost 8%).
binarytrees 0.159 → 0.121 s (wall 0.116 → 0.086), tilemap 0.27 → 0.24.

**Warm-up, measured by the wall clock** (was item 3). bench.sh reports wall
time next to `TIME`: much of what read as warm-up cost on the short
benchmarks was V8's helper threads (strings `TIME` 0.16, wall 0.09; hashtab
0.145 and 0.091 — faster than lua5.5's 0.096; closures 0.094 and 0.066). A
larger young generation is no general cure, in wall time: with
`--min-semi-space-size=16` / `64` hashtab 0.093 → 0.080 / 0.075, but strings
0.095 → 0.095 / 0.106 and closures 0.063 → 0.070 / 0.083. Heap flags can't be
set from inside the host anyway; an embedder that knows its workload can.

Maybe-typed locals ([note 22](design/22-maybe-typed-locals.md)), table shapes
and inline caches ([note 23](design/23-table-shapes.md)), run-once loop
outlining ([note 24](design/24-run-once-loops.md)), the fast/slow helper splits
and what V8 inlines ([lessons](lessons.md)).
