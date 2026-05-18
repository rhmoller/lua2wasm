# Design: string.pack / string.unpack / string.packsize

## Goal

Implement Lua 5.5's three binary-serialization builtins on the `string`
library:

- `string.pack(fmt, v1, v2, …)` — returns a binary `$LuaString` whose
  bytes are `v1, v2, …` laid out per `fmt`.
- `string.unpack(fmt, s [, pos])` — decodes `s` starting at `pos`
  (1-based; default 1), returns the decoded values followed by the
  position one past the last consumed byte.
- `string.packsize(fmt)` — returns the byte length a `pack` with this
  `fmt` would produce. Errors if `fmt` contains a variable-length
  option (`s` or `z`).

Spec source: `lua-5.5.0/doc/manual.html` §6.5.2 ("Format Strings for
Pack and Unpack"). Reference C source (`lstrlib.c`) is **off-limits**
per `docs/lessons.md` — clean-room from the manual.

## Format options (recap)

```
< > = ! ![n] b B h H l L j J T i[n] I[n] f d n c[n] z s[n] x Xop ' '
```

| Group | Options | Notes |
|---|---|---|
| Endianness | `<` `>` `=` | LE, BE, native. Reset stays sticky until next option. |
| Alignment | `![n]` | Sets max alignment; default `!1` (no align). `n` ∈ 1..16; must be a power of 2. |
| Signed int | `b` `h` `l` `j` `i[n]` | Sign-extend on unpack; overflow-check on pack. |
| Unsigned int | `B` `H` `L` `J` `T` `I[n]` | Zero-extend. |
| Float | `f` `d` `n` | 4 / 8 / 8 bytes via IEEE-754 bitcast. |
| String | `c[n]` `z` `s[n]` | Fixed / zero-terminated / length-prefixed. |
| Padding | `x` `Xop` | One zero byte / align-only no-op. |
| Filler | space | Ignored. |

For `!n`, `s[n]`, `i[n]`, `I[n]`: `n` ∈ 1..16.

Per the manual, every format string starts as if prefixed by `!1=`:
no alignment, native endianness.

### Our "native" sizes

Reference Lua picks native sizes from the host C compiler. We are
clean-room with WASM, so we **pick once** and document. These match
the typical 64-bit Linux Lua build, which is what users expect:

| Option | Bytes |
|---|---|
| `h` `H` | 2 |
| `i` `I` (no `[n]`) | 4 |
| `l` `L` | 8 |
| `j` `J` | 8 (Lua integer) |
| `T` | 8 (size_t-equivalent) |
| `f` | 4 |
| `d` `n` | 8 |

Native endianness: **little-endian** (WASM is LE-only). So `=` is
identical to `<`.

### Alignment rule (verbatim from the manual)

> For each option, the format gets extra padding until the data starts
> at an offset that is a multiple of the minimum between the option
> size and the maximum alignment; this minimum must be a power of 2.

Concretely: with `max_align = A` and option size `S`,
`stride = min(A, S)`; insert `(-offset) mod stride` padding bytes
before the option. If `stride` is not a power of 2 we raise (e.g.
3-byte option under `!4`).

`c` and `z` are explicitly NOT aligned. `s[n]` takes the alignment of
its `n`-byte size prefix.

## Strategy

The format string is tiny (~tens of chars) and is parsed once per
call. No bytecode compilation — just walk the format twice for `pack`
(once to size, once to fill) or once with appending for `unpack` and
`packsize`. Mirrors the pattern milestone's lesson that "don't
pre-compile the cheap case".

```
$fmt_scan(fmt, callback, state):
  loop over fmt bytes:
    skip spaces
    decode one option (incl. optional [n] suffix)
    callback(option, n, state)
```

For `packsize`: callback accumulates `(padding + size)` per option,
raises on `z`/`s`.

For `pack`: two passes. Pass 1 walks the format to compute the total
size; pass 2 allocates `(array.new $LuaArr 0 total)` and walks again
to write bytes.

For `unpack`: one pass, reading bytes and pushing decoded values onto
a growing `$ArgArr`.

> Why two passes for `pack` and not for `unpack`?
> — `pack`'s output size depends only on the *format and arg lengths*,
> both available without writing; pre-sizing avoids a `$Builder` grow
> loop. `unpack`'s output count equals the option count and is also
> known after a format-only walk, so we could pre-size the `$ArgArr`
> the same way. **Yes — do that too**, so both entries allocate once.

## State machine

Carry through the scanner:

```wat
(type $PackState (struct
  (field $endian_le (mut i32))   ;; 1 = little-endian, 0 = big-endian
  (field $max_align (mut i32))   ;; current max alignment (default 1)
  (field $offset    (mut i32))   ;; bytes written / read so far
  (field $opt_count (mut i32)))) ;; number of value-bearing options seen
                                 ;; (drives the $ArgArr size for unpack)
```

Configuration options (`<`, `>`, `=`, `!`, `Xop`) only mutate state;
they do not advance any arg or value cursor.

## Option-by-option semantics

### Integers

Pack signed `b h i[n] l j`:
1. Take arg as `i64` via `$as_int`.
2. Range-check against `[-2^(8n-1), 2^(8n-1)-1]`; error if outside.
3. Add alignment padding.
4. Write `n` bytes from low to high (LE) or high to low (BE).

Pack unsigned `B H I[n] L J T`:
1. Take arg as `i64`. Lua treats it as unsigned for the size check:
   reject only if `n < 8` and `arg >> (8n) != 0` (any high bit set
   above the field).
2. Otherwise same as signed.

Unpack signed:
1. Add alignment padding.
2. Read `n` bytes into an `i64` (LE or BE).
3. Sign-extend from `8n`: `(x << (64 - 8n)) >> (64 - 8n)` arithmetic.
4. Push as Lua integer.

Unpack unsigned:
1. Read into `i64` zero-extended.
2. If the result doesn't fit a Lua integer (top bit set on an 8-byte
   read), per the manual `unpack` raises overflow.
3. Push as Lua integer.

### Floats

`f` (4 bytes): take arg as `f32` via `f32.demote_f64(as_float(arg))`,
reinterpret to `i32`, write 4 bytes LE/BE.

`d` and `n` (8 bytes): `as_float(arg)` → `i64.reinterpret_f64`,
write 8 bytes LE/BE.

Unpack: reverse — read bytes, assemble `i32` or `i64`,
`f32.reinterpret_i32` / `f64.reinterpret_i64`, promote f32→f64 if
necessary, push as Lua float.

### Strings

`c[n]`: pack writes the bytes of the arg `$LuaString`, padded with
zeros to `n`. If `len > n`, raise. Unpack reads exactly `n` bytes and
pushes them as a new `$LuaString` (no NUL stripping).

`z`: pack writes the bytes of the arg, then a single `0x00` byte.
Raise if the arg contains an embedded `0x00`. Unpack reads until the
next `0x00`, pushes the bytes before it, advances past the `0x00`.

`s[n]`: pack first writes the byte length as an unsigned int of `n`
bytes (subject to alignment and endianness, like `In`), then writes
the bytes themselves (no alignment between header and payload).
Default `n = 8` (size_t). Raise if length doesn't fit in `n` bytes.
Unpack reverses.

### Padding

`x`: write one zero byte (pack) / advance one byte (unpack). No
alignment.

`Xop`: parse the following option, take its *size only*, align as if
that option were about to be emitted, but don't read or write any
value or any of the option's payload.

## Entry-point sketches

### `string.packsize(fmt)`

```
state = { endian_le=1, max_align=1, offset=0 }
for each option in fmt:
  if option is 's' or 'z': raise
  if option is configuration: update state
  else: state.offset += pad(state, size) + size
return state.offset as Lua int
```

### `string.pack(fmt, ...)`

```
state, arg_idx = init, 1
total = packsize_walk(fmt)         ;; first pass
out = array.new $LuaArr 0 total
for each option in fmt:
  if configuration: update state
  elif padding (x): write 0, advance
  else: write arg[arg_idx]; arg_idx += 1
return $LuaString(out)
```

### `string.unpack(fmt, s [, pos])`

```
state, arg_idx = init, 0
nval = count_value_options(fmt)
res = array.new $ArgArr null (nval + 1)   ;; values + final pos
state.offset = pos - 1   ;; 0-based
for each option in fmt:
  if configuration: update state
  elif padding (x): advance
  else:
    val = decode(state, s.bytes)
    array.set $ArgArr res arg_idx val; arg_idx += 1
array.set $ArgArr res nval ($make_int (state.offset + 1))
return res
```

## Helper signatures (in WAT)

```wat
;; Pad bytes for current option of size $sz given $max_align.
;; Returns padding count; advances state.offset accordingly.
(func $pack_pad
  (param $state (ref $PackState)) (param $sz i32)
  (result i32))

;; Parse an optional [n] suffix at $fmt[$ppos+1]; returns
;; (default_if_absent_or_n, new_ppos). Default is per-caller (e.g.
;; size_t for s, native int for i/I, 1 for !).
(func $pack_n_suffix
  (param $fmt (ref $LuaArr)) (param $ppos i32) (param $default i32)
  (result i32 i32))

;; Read/write n bytes at $buf[$off]. Endianness from state.
;; Returns the i64 value (for read) / nothing (for write).
(func $pack_write_int
  (param $buf (ref $LuaArr)) (param $off i32) (param $n i32)
  (param $le i32) (param $val i64))
(func $pack_read_int
  (param $buf (ref $LuaArr)) (param $off i32) (param $n i32)
  (param $le i32) (result i64))

;; Sign-extend an $n-byte value loaded into an i64.
(func $pack_signext (param $val i64) (param $n i32) (result i64))

;; Overflow check for pack: returns 1 if $val fits in $n bytes
;; under $is_signed semantics; 0 otherwise.
(func $pack_fits
  (param $val i64) (param $n i32) (param $is_signed i32)
  (result i32))
```

The float read/write uses `f32.reinterpret_i32` / `i32.reinterpret_f32`
and the i64 equivalents directly inline — no separate helper.

## Implementation order and per-step fixtures

| Step | What | Fixture |
|---|---|---|
| 1 | `$pack_pad` + `$pack_n_suffix` + `packsize` for fixed-size options (no s/z). Covers parser, alignment math, the power-of-2 check, and `Xop` walking. | `string.packsize` only, ~12 assertions across native ints, `c[n]`, `!n`, `x`, `Xop`. |
| 2 | `pack`/`unpack` for unsigned ints (`B H I[n] J L T`), LE only, no alignment. Round-trip. | round-trip ~10 values; verify `pos` return from unpack. |
| 3 | Signed ints (`b h i[n] j l`). Sign-extend + overflow check. | round-trip including negative values; overflow-raises fixture under `pcall`. |
| 4 | Endianness flags `< > =`. Per-option BE byte ordering. | pack same value under `<` and `>`; verify byte order; cross-endian unpack. |
| 5 | Alignment (`![n]`) + `x` + `Xop`. Including the power-of-2 reject. | a struct with mixed sizes that needs interior padding; assert exact byte layout. |
| 6 | Floats `f d n`. Bitcast + endian byte order. | round-trip `pi`, `inf`, `-0.0`, `nan` (testing via bit pattern, since `nan != nan`). |
| 7 | Fixed-size strings `c[n]`. Pad-on-pack, raise-on-too-long. | round-trip; truncation-error path under `pcall`. |
| 8 | `z` and `s[n]`. `packsize` raises for both. | round-trip with embedded high bytes; verify `packsize` error; `s1` overflow-raises if length > 255. |
| 9 | Soak fixture: long mixed format, packed and re-unpacked. Cross-check expected bytes against reference Lua (oracle only — fixture authored from the manual first). | one big assertion block. |

Each step closes with a green `ctest`.

## Existing helpers to reuse

- `$args_at`, `$args_first`, `array.len $ArgArr` — arg plumbing.
- `$as_int`, `$as_float`, `$is_int`, `$is_float` — arg coercion.
- `$make_int`, `$make_float`, `$LuaString` constructor.
- `array.new $LuaArr 0 N` + `array.set $LuaArr buf i byte` — building
  the output buffer.
- `array.get_u $LuaArr buf i` — reading the subject string for unpack.
- `array.copy $LuaArr $LuaArr` — `c[n]` and `z`/`s` body copies.
- `throw $LuaError` for the various raise paths.

No new types needed beyond the small `$PackState` struct above; even
that could be three locals threaded through helpers, but a struct is
clearer at the cost of one allocation per top-level call.

## Out of scope

- Mixed-endian formats. The manual explicitly says these are not
  emulated.
- `n > 16` for `!n` / `s[n]` / `i[n]` / `I[n]`. Manual specifies 1..16.
- Honouring host-platform float endianness separately from int
  endianness. WASM has only one float byte order; we follow the int
  one.
- "Native" choices that change per build. Our native sizes are fixed
  forever (documented in the table above).

## Risk register

- **i32.and is not short-circuiting** (per `lessons.md`). The bounds
  checks in `$pack_read_int`/`$pack_write_int` will read array bytes
  in conditions like `(i32.and in_bounds (read_byte_eq_x))`. Use
  `if/then/else` for any byte-read guarded by a length check.
- **Sign vs unsigned overflow.** `$pack_fits` must distinguish: for
  signed n=1, valid range is `[-128, 127]`; for unsigned n=1,
  `[0, 255]`. Off-by-one on the negative boundary is the classic bug.
- **Endianness state is sticky.** A `>` flag affects every subsequent
  option until another flag. Easy to test with `<i4>i4`.
- **`Xop` size parsing.** We need to parse the option-letter (and any
  `[n]` suffix) without advancing arg/value cursors. Reusing
  `$pack_n_suffix` from a dispatch table is the cleanest path.
- **`packsize` of `s[n]` is variable**, but `packsize` of `c[n]` is
  fixed. The error path is "s or z only".
- **Float NaN round-trip.** Comparing `nan == nan` is false. Tests
  must compare *bit patterns* after unpack, or use `nan ~= nan`.

## Acceptance criteria

When the milestone closes:

- All three entry points pass against fixtures derived from the
  manual's option list, plus the soak fixture in step 9.
- Cross-check: every value in the soak fixture round-trips
  (`unpack(pack(v))` = `v`) and the packed bytes match reference Lua
  byte-for-byte (oracle comparison, not source-copy).
- `packsize`'s "no s or z" error is catchable through `pcall`.
- `lessons.md` retro entry: did the design hold? Did any of the
  risk-register items bite? Any cascading bugs in existing prelude
  helpers exposed by the new alignment math?
