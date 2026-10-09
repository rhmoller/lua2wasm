# Performance backlog

Bottlenecks with the evidence and a fix sketch for each, what has landed
(Done) and what was measured and set aside. Snapshot of 2026-10-09, after
working through the list of 2026-10-08. Update it when an item lands or a
measurement changes.

## Where we stand

Seconds (`TIME`, best of five) on one machine, Node 24. `TIME` is
`os.clock()`, CPU time, which for lua2wasm includes V8's background compiler
and parallel GC threads; `wall` is the same run timed by the wall clock
(`LUA2WASM_CLOCK=wall`), the fairer comparison with single-threaded Lua:

| bench | lua5.5 | lua2wasm | ratio | wall | wall ratio |
|---|---:|---:|---:|---:|---:|
| binarytrees | 0.355 | 0.113 | 0.32× | 0.087 | 0.25× |
| fannkuch | 0.821 | 0.327 | 0.40× | 0.325 | 0.40× |
| spectralnorm | 0.955 | 0.526 | 0.55× | 0.521 | 0.55× |
| oo | 0.458 | 0.271 | 0.59× | 0.248 | 0.54× |
| nbody_arr | 0.380 | 0.234 | 0.62× | 0.227 | 0.60× |
| vectors | 1.081 | 0.668 | 0.62× | 0.621 | 0.57× |
| particles | 0.586 | 0.453 | 0.77× | 0.416 | 0.71× |
| tilemap | 0.289 | 0.226 | 0.78× | 0.179 | 0.62× |
| nbody | 0.434 | 0.350 | 0.81× | 0.345 | 0.79× |
| entities | 0.676 | 0.558 | 0.83× | 0.493 | 0.73× |
| closures | 0.074 | 0.070 | 0.95× | 0.047 | 0.64× |
| hashtab | 0.097 | 0.122 | 1.26× | 0.077 | 0.79× |
| strings | 0.068 | 0.129 | 1.90× | 0.073 | 1.07× |

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
  removed), `--wasm-tiering-budget=N` (earlier tier-up), `--trace-gc`
  (its lines interleave with a micro's laps, so each section shows its
  scavenges), `--liftoff-only` / `--no-liftoff` (one tier only),
  `--wasm-sync-tier-up --wasm-tiering-budget=1` (all optimizing compilation
  on the main thread, so the wall clock shows what it costs).
- `grep` on the dev machine is ugrep: a `$` inside a pattern is an anchor, so
  use `grep -F` for WAT names like `$ol_2`.
- An unrelated change can move a benchmark by 5–10% (binarytrees, vectors):
  V8's inlining budget and tier-up timing shift with the module's function
  indices and sizes. Before blaming or crediting a change, A/B it against the
  previous commit with alternating runs on the wall clock, and diff the
  generated user code and `INLINING=` traces. `ops.lua` times each
  operation's third run, which can still start on baseline code if
  optimization finished late: `s:byte(i)` reads 16 or 31 ms depending on the
  build (16 alone).

## Backlog

Every item of the 2026-10-08 list has landed (under Done) or was measured
and set aside (below). What remains between lua2wasm and lua5.5 on this
suite is strings — 0.073 against 0.068 s by the wall clock (0.087 before
items 1 and 2, see Done) — and the string runtime itself is not the slow
part. Warm, it makes short strings faster than lua5.5, which interns each
one and formats integers with `snprintf` (1M of each, ms: `tostring(i)` 16
against 77, a fresh string `==` a constant 16 against 49, `t[fresh key]` 35
against 54, `s:sub` of 6 bytes 19 against 29), and `string.format` runs at a
third of lua5.5's time.
bench/strings.lua's sections before item 1 (`strings_sections.lua` cold, by
the wall clock; `strings_warm.lua` warm), in ms:

| section | lua5.5 | cold (wall) | warm |
|---|---:|---:|---:|
| build | 13.8 | 19–28 | 4.8 |
| tconcat | 2.0 | 5.7 | 3.4 |
| gmatch | 12.8 | 21 | 13.7 |
| gsub | 1.3 | 2.3 | 1.8 |
| byte | 3.3 | 5.0 | 3.8 |
| concat | 3.5 | 10.5 | 12.4 |
| format | 30 | 20 | 10.8 |

The difference is the first run and large strings, items 1–4 (items 1 and
2 have landed, item 4 is set aside). Summed over the sections `TIME` reads 172 ms
against 83 by the wall clock: half of the 2.3× that the table at the top
read then is V8's helper threads.

**3. Strings that survive.** Every string is two GC objects, and a program
that keeps them pays the scavenger to copy each one out of the nursery
while V8 grows the nursery to fit (1 → 16 MB). In bench/strings.lua's
`build` (200k strings kept in `parts`) five scavenges take ~16 of 29 ms
(`--trace-gc`); with the nursery fixed at 16 MB from the start `build`
takes 9.5 ms, warm 4.8 against lua5.5's 13.8. lua5.5 hardly allocates
there: interned, the 200k results are 70 strings. The garbage collector is
23% of the benchmark's main-thread profile. No cheap fix (see "One GC object
per string" and "Interning" below); a nursery size suits one section and
hurts another (`--min-semi-space-size=16` takes `build` 25 → 9.5 ms;
`--min-semi-space-size=64` takes `concat` 10 → 35).

## Measured and set aside

**Splitting `string.format` for an earlier tier-up** (item 4 of the
2026-10-09 list).
`format` runs 20 ms cold (wall) against 10.8 warm, `gmatch` 21 against
13.7, while the big builtins run on Liftoff and TurboFan compiles them in the
background. `--wasm-sync-tier-up --wasm-tiering-budget=1` (all optimizing
compilation on the main thread) adds ~55 ms to the sections' 83, but
`--trace-wasm-compilation-times` shows the largest function compile is
`$builtin_string_format` at 5 ms. `string.format` 100k times in a fresh
process, by 10k-call blocks: 5.6 ms for the first block (Liftoff, 4–5 ms a
block there), ~3 for the next two, ~1.2 once optimized. The other slow
blocks, 3–4 ms, are scavenges promoting the kept results, which a split
can't reach. A smaller driver would at best shorten the 5 ms compile wait
(~2 ms of Liftoff time), and its helpers would cost calls in steady state
wherever V8 doesn't inline them.

**One GC object per string** (from item 2). Allocating and keeping 200k
short strings as a struct plus its byte array costs 7.2–8.0 ms against 6.2
for the array alone (a standalone wasm loop): 5–8 ns per string, so at most
~4 ms of strings' 87 ms (it makes ~500k strings) and ~1 ms of hashtab's —
before paying for a 4-byte offset on every byte access and four byte loads
per cached-hash read. Not worth rewriting the 360 prelude sites that touch
`$LuaString`.

**Interning short run-time strings** (from item 2). It would pay a hash and
a table probe at every string creation for pointer-equality key compares;
string-key access already runs at a third of lua5.5's time (`ops.lua`: 9
against 26 ms), identity first and cached hashes after. It would have spared
bench/strings.lua's `build` its survivors (item 3: 200k strings, 70
distinct), but WasmGC has no weak references, so an intern table could
never let go of a string without the host's (JS `WeakRef`) help; and on
unique strings interning is what makes lua5.5 slow — keeping 200k unique
short strings takes it 36 ms against our 6.

**Wide integers in table slots** (from item 2). An integer from 2^30 up
stored in a table is still a `$LuaInt`; the float storage's marker scheme
could carry it unboxed (a second marker, the i64 in the f64 slot). No
benchmark stores such values in bulk; worth doing for code that keeps
hashes or 64-bit state in arrays.

**A node array for the hash part** (item 6, see Done): conflicts with
shared shapes.

**Every inner loop of an outlined loop in a function of its own** (item 8,
see Done): cost fannkuch / particles 2% and up to 13% module size.

## Done

**Lazy strings for long concatenations** (item 2 of the 2026-10-09 list;
[note 25](design/25-string-ropes.md)). `acc = acc .. x` is quadratic in
lua5.5 too, but here each step's copy also lands in fresh, zero-filled
nursery memory (WasmGC has no uninitialized allocation): 20,000 10 KB
`array.new` + `array.copy` take 7.7 ms optimized, 1.0 of it the copies, and
49 ms on Liftoff, where `array.new` fills a byte at a time; past 128 KB it
was 5–9× slower than lua5.5. Now a `..` result of 128 bytes or more is lazy
— a node over its operands, or, once a loop appends to a node it hasn't
read, a version of a growable append buffer whose latest version appends in
place — and is flattened into one array on the first read of its bytes
(`$str_bytes`, which all 63 byte reads go through; `#s` reads `$len`). The
concat section 11.1 → 1.3 ms (lua5.5 3.5), 1M small appends 21 ms (lua5.5
12.9 s), bench/strings.lua 0.087 → 0.078 s (median of 11, wall). Measured
against it: nodes only (64 bytes kept per small append; 1M of them left a
67 MB heap, ~95 of 130 ms in the scavenger) and nodes merging short appends
into the last leaf (35.7 ms for the 1M appends, simpler, faster for 1 KB
pieces). `$str_bytes` in every inlined caller cost `s:byte(i)` 15% of its
inlining budget until `$as_int_co` took a small-integer fast path (`s:byte`
23.4 → 17.2 ms, `s:sub` 17.3 → 14.2).

**Results built in one allocation** (item 1 of the 2026-10-09 list). A builder result
(`string.format`, `gsub`, `table.concat`) used to start in a fresh `$Builder`
(a struct and a 32-byte array), double its array as it grew (each a fresh,
zero-filled copy) and copy it once more to the exact size in
`$builder_finish`: 4–6 allocations for a short `string.format` result, ~2.6
MB of doublings plus a 1.3 MB trim for tconcat's result. Now `table.concat`
over a table without a metatable whose range sits in the array part
(`$tab_concat_arr`) sums the pieces' lengths, allocates once and writes each
piece, integers in place; anything else (a float, a hole, the hash part, a
metatable) takes the general path. The builder users take one reused
builder (`$builder_take` / `$builder_give`; a nested call — a `__tostring`
under `%s`, a `gsub` callback — finds it taken and makes its own, and one
grown past 64 KB isn't kept), `$fmt_int` / `$fmt_fixed` write digits into a
shared scratch array instead of a fresh one per conversion, and a `gsub`
that matched nothing returns its subject, as lua5.5 does. Warm, by the wall
clock (ms, lua5.5 in brackets): `table.concat` of 200k strings 3.6 → 1.7
(2.1), of 200k integers 5.9 → 3.3 (11.4), of 10 strings 100k times 14.5 →
7.5 (13.9); `string.format` 100k–200k times 8–15% faster. `gsub` is
unchanged: its time is the matcher, the argument arrays and the capture
array it allocates per call. bench/strings.lua 0.092 → 0.081 s (median of
15, wall), `TIME` 0.152 → 0.136. Compare sections by their sum: with less
garbage from `table.concat` the collections land elsewhere — in
`strings_warm.lua` a scavenge and a mark-compact move into `gmatch` and
`gsub`, whose warm times rise 2.6 and 0.9 ms. Its warm sections sum to the
same (48.5 against 48.7 ms, best of five each); its first run drops 86.8 →
79.4.

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

**The generic for without the call protocol** (was item 5, and item 8's
iterator bullet). A generic for with one or two variables picks a mode once
(`$for_gen_mode`): over `ipairs` it counts the index itself and reads `t[i]`
through the inline array probe; over `next` (what `pairs` returns) it
carries a position into the array part and then the hash part
(`$next_step`) instead of looking the key up again each step — the same
entries in the same order, since clearing fields keeps positions and adding
one mid-traversal is undefined in Lua. Any other iterator is called; with one
variable through its fast entry, which gmatch's iterator now has (its
capture buffer is reused across calls instead of allocated per match).
`iter.lua`: ipairs 18.8 → 4.1 ms (a numeric for: 4.3), pairs over an array
17.5 → 4.5, over a hash 40.2 → 6.3 (lua5.5: 25, 23, 66); strings' warm
`gmatch` 31.9 → 14.5 ms (lua5.5 13.7). Fixed on the way: `pairs` honours
`__pairs` (its first four results), and `ipairs` indexes any value as
`lua_geti` does (`ipairs("abc")` yields nothing).

**Array append and `#t`** (was item 7). `t[#t + 1] = v` used to be
`$lua_tabset(t, $lua_add($lua_len(t), 1), v)`, all boxed. Now `#x` is an
opaque number to the maybe-typed lowering — read inline (the array part's
length) for a table with no metatable and no hash keys — so `#t + 1` lowers,
and a store whose key is a lowered tree takes the cell-keyed path. A key
spelled `#t + 1` also appends inline when the table has no metatable, no
hash keys to absorb and room in its array; other integer-key stores leave
the append to `$lua_tabset_ik_miss`, which does the same before the full
path (an inline append at every store site cost fannkuch 4.5%). `$tab_len`
and `$arr_append` no longer probe the hash part for key `#t + 1` when the
table has no hash keys. `ops.lua`: `t[#t + 1] = i` 28.2 → 7.7 ms (lua5.5
14.6), `t[i] = i` 11.6 → 6.4 (5.8); closures 0.083 → 0.069 s.

**Run-once outlining, wider** (was item 8; [note 24](design/24-run-once-loops.md)).
A function handed to `pcall` / `xpcall`, a global `function main() ... end`
defined and called once (in a globally closed program), and a local function
called once from any run-once body (not only the main chunk) now run once,
so their loops are outlined: a 20M-iteration loop inside
`pcall(function() ... end)` or `main()` 0.124 → 0.063 s. A numeric for
directly inside an outlined numeric for with few constant iterations can
continue in a function of its own when it has more than a budget left: the
first of six frames around a 2M-iteration loop 12.6 → 7.6 ms (later frames
6.4). Splitting every inner loop cost fannkuch / particles 2% and up to 13%
module size, so it is limited to that shape.

**The hash part** (was item 6). Kept its layout — an index of positions
over the shape's keys and the table's values — rather than reference Lua's
node array (key, value, chain): a record's keys live in its `$Shape`, shared
by every table built alike and the basis of the inline caches
([note 23](design/23-table-shapes.md)), which an interleaved node array
can't share. Measured against lua5.5 it was already level or ahead
(`ops.lua`: string keys 9 against 27 ms, sparse integer keys 18 against 18;
hashtab faster by the wall clock), with rebuilds at 6% and lookups ~10% of
hashtab's profile. Two cheap fixes instead: the collision probe compares a
small integer, table, boolean or function key by identity alone (stored
integer keys are normalized, so only a wide integer or a float needs the
value compare), and `$lua_hash` reaches table keys before the number tests.
Sparse integer keys 18.2 → 17.1 ms, hashtab 0.083 → 0.080 s wall.

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
