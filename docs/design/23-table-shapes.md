# 23 — Table shapes and inline caches

Status: in progress (2026-10).

## Problem

After the string-key work (hoisted constant keys, cached hashes, a
string-specialized probe) more than half the self time of the OO-style
benchmarks (`oo`, `entities`) is still spent in string-keyed table
operations, and a third or more in `vectors` / `tilemap`:

- **Construction.** `{x = x, y = y}` allocates the table struct, a key array,
  a value array and an index array (plus an `f64` array when a float is
  stored unboxed), grows them from empty and hashes every key into the index.
  Reference Lua allocates the struct and one node array.
- **Field access.** Every `t.name` probes the index: load the index array,
  mask the cached hash, load the slot, load the key, compare.
- **Method calls.** `obj:m()` misses on the instance (a probe), probes the
  metatable for `__index`, then probes the class table: three probes per
  call, ~55% of a method-call microbenchmark.

## Representation

The hash part's *key layout* moves out of the table into a `$Shape`:

| `$Shape` field | meaning |
|----------------|---------|
| `$keys` | keys in insertion order, `[0, n)` |
| `$idx`, `$mask`, `$used` | open-addressing index over `$keys` (as before) |
| `$n` | number of keys |
| `$tkeys`, `$tkids` | transition cache: key → child shape |

A table keeps its *values* (`$vals[pos]`, `$fvals[pos]` for unboxed floats)
and a `$shape` reference. Position `pos` of a key is fixed by the shape, so
every table with a given shape stores a given key at the same position.

A table is in one of two modes:

- **Shared** (`$own = 0`). The shape is immutable and may be shared by any
  number of tables. Adding a key moves the table to a *child* shape — the
  parent's keys plus the new one — found in the parent's transition cache or
  created and cached there. Tables built by adding the same keys in the same
  order therefore end up with the *same* shape object, like V8's hidden
  classes. Every empty table starts on the global root shape.
- **Owned** (`$own = 1`). The table has a private shape that it mutates in
  place — the old hash-part algorithm, including compaction of deleted
  entries. A table switches (clones its shape) when it outgrows
  `SHAPE_SHARE_MAX` keys or gets a non-string key in its hash part: those are
  dictionaries, where per-key transitions would only churn shapes.

Deleting a key (`t.k = nil`) never changes the shape: the value slot is
cleared (lazy deletion, as before), so the key is still found — at the same
position, which `next()` relies on — and a later store refills the slot.

The transition cache is small and direct-mapped by key hash (eviction just
means a later table gets an equal but distinct shape). Matching is by key
identity: constant keys are hoisted module globals, so every site using a
literal key passes the same object; a dynamic string with equal bytes merely
misses the cache. Correctness never depends on sharing.

## Construction

A table constructor whose string keys are all constants (distinct, at most
`SHAPE_SHARE_MAX`) knows its final layout statically. Each such site caches
its shape in a module global (built once, through the transition tree, so it
is the same shape incremental construction reaches) and builds the table as
the struct plus one value array filled in field order.

## Inline caches

A constant-key access site `t.name` remembers the last shape it saw and the
key's position in it. When the table's shape is that shape, the value is
`$vals[pos]` — one identity check instead of a probe. A method call
additionally remembers that the receiver's shape *lacks* the key (absence is
a property of the shape, since string keys only ever live in the hash part)
and the class table's shape/position, so `obj:m()` becomes three identity
checks when monomorphic.

## Semantics notes

- `pairs` order is unchanged: keys keep their insertion order, deleted keys
  keep their position until an owned table compacts.
- Nothing here depends on a value being present: a cached position whose
  value is nil is a miss and takes the slow path (`__index` etc.).
