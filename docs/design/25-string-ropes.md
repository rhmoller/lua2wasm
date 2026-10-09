# 25 — Long concatenations as lazy strings

Status: implemented (2026-10).

## Problem

`acc = acc .. x` in a loop is quadratic in reference Lua too: each step
copies the whole string. lua5.5 pays for that with `malloc`/`memcpy` into
the block its allocator just freed, still in cache. Here every new string is
an `array.new` — fresh, zero-filled nursery memory (WasmGC has no
uninitialized allocation) — and then an `array.copy`. A wasm loop of 20,000
10 KB arrays allocated and copied takes 7.7 ms optimized, of which the copies
are 1.0: the cost is the fresh memory. It grows with the nursery's size (the
warm `acc` loop 4.4 ms at ~2 MB, 9.6 at 64 MB), and on Liftoff, where V8
fills a new array a byte at a time, the same loop takes 49 ms; V8 tiers
`$lua_concat` up late, since it counts instructions executed, not bytes
moved. With longer strings it gets worse: 200k one-byte appends take 2.5 s
(lua5.5: 0.29), 200k 16-byte ones 52 s (lua5.5: 10.7).

## Design

A `..` whose result is at least 128 bytes long does not copy its operands.
It makes a lazy string: `$bytes` null until something reads them, the length
in `$len`. There are two kinds, both subtypes of `$LuaLazy`, itself a
`$LuaString` to everything that tests or casts for one (`type`, table keys,
identity):

```
(type $LuaString (sub (struct (field $bytes (mut (ref null $LuaArr))) (field $hash (mut i32)))))
(type $LuaLazy   (sub $LuaString (struct ... (field $len i32))))
(type $LuaRope   (sub final $LuaLazy (struct ... (field $left (mut (ref null $LuaString)))
                                                 (field $right (mut (ref null $LuaString))))))
(type $StrBuf    (struct (field $arr (mut (ref $LuaArr))) (field $used (mut i32))))
(type $LuaBufStr (sub final $LuaLazy (struct ... (field $buf (mut (ref null $StrBuf))))))
```

**Nodes.** A `$LuaRope` is a node over the two operands.

**Append buffers.** A `$LuaBufStr` is a version of a growable buffer: its
contents are the buffer's first `$len` bytes. A buffer's bytes below `$used`
are written once and never change (growing copies them into the new array),
so every version reads its own prefix. `s .. x` with `s` the buffer's latest
version (`s.len == buf.used`) writes `x` at `$used`, growing the array to
twice the length when it is full, and returns a new version: an append
copies only its piece and allocates one small struct, and nothing stays
alive but the buffer and the newest version. Appending to an older version
(a fork: `v1 = s .. "a"; v2 = s .. "b"`) makes a node instead.

**Which kind.** An append to a node that hasn't been read means a loop is
appending without reading, so it starts a buffer: the node's leaves and the
new piece are copied into an array of twice the total. Any other long
result is a node, including the first append to a flat string. So a loop
that reads its string every step (`acc = acc .. x; if acc:byte(-1) ...`)
never pays for a buffer it can't use: each step makes a node and the read
flattens it.

**Reading.** Every byte read in the runtime goes through `$str_bytes`, which
returns `$bytes` or flattens the lazy string (`$lazy_flatten`): one exact
array of the full length, kept in `$bytes`, after which the node's operands
or the buffer are dropped — a finished string doesn't keep spare capacity
alive. `$lazy_write` fills the array right to left: a node continues with
its right operand and leaves its left one on a stack (which only grows for a
rope built by prepending), and a flat string or a buffer version is a leaf.
The allocation sits in `$lazy_write`, the function with the loop, because V8
optimizes that soon; split from it, the allocating function stayed on
Liftoff and the append-and-read loop's first call took 49 ms instead of 13.

**What doesn't flatten.** `$str_length` reads `$len`, so `#s`, `string.len`
and `rawlen` never flatten. `$str_eq` settles two strings of different
lengths without flattening either. `..` on a lazy string makes another one,
or, when the result is under the minimum, copies (an operand of such a
result is shorter than the minimum, so it is flat). `$lua_concat3` / `4`
(codegen's flattened chains) below the minimum still write everything into
one array; at or above it they concatenate pairwise from the right, so
`acc .. x .. y` appends a flat `x .. y`. `table.concat`'s sized fast path
sums lengths with `$str_length` and flattens a lazy element when it writes
it.

**Why 128.** Below that, strings are words, keys and lines: they are hashed
and compared, which would flatten a lazy string at once, and copying them
costs about what a struct does. JS engines make ropes from 13 characters,
but their flattening is cheaper to reach.

## Cost

Every byte read gains a null check: the 63 `struct.get $LuaString $bytes`
sites became `call $str_bytes`, and the embedding API's `lua_str_setb` too.
`$bytes` is now mutable. `$str_bytes` is kept small (24 bytes) because V8
inlines it everywhere and each byte comes out of the inlining budget of the
function it lands in: in a loop of `s:byte(i)`, its first version cost the
inlining of `$as_int_co` and made the loop 15% slower. `$as_int_co` now
reads a small integer itself and leaves coercions to `$as_int_co_slow`,
which frees more budget than `$str_bytes` takes (below). Equality of a fresh
string and a constant is ~1 ns slower (`$str_eq` tests both `$bytes` for
null).

## Results

Wall clock, ms. "Merging" is the alternative below: nodes only, with short
appends merged into the last leaf.

| | before | merging | buffers | lua5.5 |
|---|---:|---:|---:|---:|
| 1M appends of a fresh one-byte string (floor: 12.6) | quadratic | 35.7 | 21.0 | 12,946 |
| 200k appends of 1 byte | 2,519 | 4.8 | 1.8 | 287 |
| 200k appends of 16 bytes, then a read | 52,145 | 7.3 | 5.4 | 10,707 |
| 2k appends of 1000 bytes, then a read | 373 | 0.4 | 1.5 | 59 |
| append and read each step ×20k: first call, warm | 47, 4.2 | 14, 4.5 | 13, 4.5 | 7, 5.4 |
| bench/strings.lua `concat` section (cold) | 11.1 | 2.1 | 1.3 | 3.5 |
| bench/strings.lua (median / min of 11) | 87 / 78 | 78 / 73 | 78 / 72 | 67 |
| `s:byte(i)` ×3M / `s:sub(i, j)` ×1M, warm | 23.5 / 16.8 | | 17.9 / 14.2 | |

The floor is the 1M-append loop's own work (the loop and its `tostring`
calls). Buffers copy a large piece where a node only links it, hence the
1000-byte row. The other benchmarks are unchanged. The sections of
bench/strings.lua move by a few ms in sections that make no lazy strings
(`build`, `gmatch`, `format`): with the concat section's 200 MB of garbage
gone, the scavenges land elsewhere.

## Alternatives

- **Nodes only** (V8's cons strings): fastest for large pieces, but a loop
  of small appends makes a node and keeps a piece per append, 64 bytes per
  appended byte, all reachable, so the scavenger copies all of it. One
  million one-byte appends left a 67 MB heap for a 1 MB string, ~95 of the
  130 ms in the scavenger, and slowed the code that ran after them.
- **Nodes with merging** (Boehm's cords): a short piece appended to an
  unread node joins its right leaf while the two stay under 128 bytes (a
  flat copy), so small appends make a node per ~128 bytes and hold ~1.5
  bytes per byte. Simpler than buffers — one kind of lazy string, no
  versions; ~90 lines of WAT against ~140 — slower for small appends (each
  copies the leaf, 64 bytes on average), faster for large pieces.
- **A length on every string** (SpiderMonkey's extensible strings, Go's
  `append`): a string's array may be longer than the string, so flattening
  can leave spare capacity and the next append writes into it. It is the
  only way to make append-and-read-each-step linear. But every string
  carries the field, every byte loop must bound itself by it instead of
  `array.len`, and appended strings keep up to half their array as slack.
- **Views** (an offset and length into a shared array, for `sub` as well):
  the same field costs, and a small substring keeps a large array alive.

## Limits

- A string read every step (`acc = acc .. x; if acc:sub(-1) == ...`) is
  flattened every step: the same copying as before, plus a node (warm, ~7%
  slower than copying; on the first call faster, since Liftoff no longer
  runs the copy). Only a length on every string fixes that.
- While it is being built, a buffer holds up to twice the string, and a
  node keeps both its operands. Reading the string once releases them.
- The host reads a lazy string's bytes (`print`, `io.write`) through the
  same exports, so it flattens it.
