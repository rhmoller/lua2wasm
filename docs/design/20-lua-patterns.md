# Design: Lua patterns

## Goal

Implement Lua 5.5's pattern subsystem:

- `string.find(s, pat [, init [, plain]])` — returns `(start, end[, caps…])` or `nil`
- `string.match(s, pat [, init])` — returns captures (or whole match) or `nil`
- `string.gmatch(s, pat [, init])` — iterator yielding successive matches
- `string.gsub(s, pat, repl [, n])` — substitute, returns `(new_string, count)`

Spec source: `lua-5.5.0/doc/manual.html` §6.4.1 ("Patterns"). Reference C
source is off-limits per `docs/lessons.md` — clean-room from the manual
and from public knowledge of Lua's pattern language.

## Pattern language (concise)

### Character classes

| Class | Matches |
|---|---|
| `x` (literal, non-magic) | itself |
| `.` | any byte |
| `%a` / `%A` | letters / non-letters |
| `%d` / `%D` | digits / non-digits |
| `%c` / `%C` | control / non-control |
| `%g` / `%G` | printable-non-space / not |
| `%l` / `%L` | lowercase / not |
| `%p` / `%P` | punctuation / not |
| `%s` / `%S` | space / not |
| `%u` / `%U` | uppercase / not |
| `%w` / `%W` | alphanumeric / not |
| `%x` / `%X` | hex digit / not |
| `%z` / `%Z` | null byte (`\0`) / non-null |
| `%<magic>` | the magic char literally (`%%`, `%(`, `%[`, etc.) |
| `[set]` | char-class set; see below |

Magic chars (require `%` to be literal): `^ $ ( ) % . [ ] * + - ?`.

### Sets

`[ ... ]` matches one byte against the body. Body contents:

- literal chars (incl. magic chars used as themselves inside a set)
- ranges `a-z` (anything but `]` is allowed at the boundaries)
- character classes `%a %d %s` etc.
- `]` as the first body char is a literal `]` (else it terminates the set)
- `[^...]` negates the set

### Quantifiers

Apply to **the immediately preceding char-class only** (a single literal,
`.`, `%X`, or `[set]`). They do NOT apply to groups, back-references,
`%bxy`, or `%f[set]`. This is a real spec point and a meaningful
simplification for the matcher:

| Op | Meaning |
|---|---|
| `*` | zero or more, greedy (longest) |
| `+` | one or more, greedy |
| `-` | zero or more, lazy (shortest) |
| `?` | zero or one |

### Anchors

- `^` at pattern position 0: anchor to the start of the subject.
- `$` at pattern end: anchor to the end of the subject.
- Anywhere else, `^` and `$` are literal characters.

### Captures

- `(pat)` substring capture — record the matched bytes.
- `()` position capture — record the current 1-based byte position
  (special sentinel; recorded as a 1-byte integer in the result, not as
  a substring).

Captures are numbered 1..N in source order of their opening `(`.

### Specials

- `%n` (n = 1..9): back-reference to the n-th capture's matched bytes.
  Must be a *closed* capture at that point.
- `%bxy`: balanced match — x must occur at the current position; the
  matcher scans forward, treating x as "open" and y as "close",
  consuming everything up to and including the y that balances the
  initial x. x and y are arbitrary single bytes (commonly `%b()` or
  `%b[]`).
- `%f[set]`: frontier — matches the empty string at the current
  position iff the byte at the previous position is NOT in `set` AND
  the byte at the current position IS in `set`. (Position 0 treats the
  "previous byte" as `\0`.)

## Capture-buffer representation

```wat
(type $CapArr (array (mut i32)))
```

A buffer of 64 `i32` cells stores up to 32 captures. Two cells per
capture:

- `caps[2*i]`     = subject byte index where capture *i* starts
- `caps[2*i + 1]` = length sentinel:
  - `≥ 0`  → closed substring capture of that many bytes
  - `-1`   → open substring capture (still on the parser stack)
  - `-2`   → position capture (`caps[2*i]` is the position, no length)

Captures nest, so the most recently opened one is always the next to be
closed (no out-of-order). On a close, the matcher walks back from
`ncaps − 1` until it finds the first `len == -1` and fixes it up.

`ncaps` is passed by value through the recursive call and returned as a
second result. Failure ⇒ caller doesn't update its own `ncaps`, so any
stale writes past the caller's `ncaps` frontier are simply ignored.

## Match function

One core recursive function:

```wat
(func $match_pat
  (param $sub (ref $LuaArr))      ;; subject bytes
  (param $spos i32)               ;; subject position (0-based)
  (param $pat (ref $LuaArr))      ;; pattern bytes
  (param $ppos i32)               ;; pattern position (0-based)
  (param $caps (ref $CapArr))     ;; capture buffer (mutated)
  (param $ncaps i32)              ;; current number of captures
  (result i32 i32))               ;; (end_spos_or_-1, new_ncaps)
```

WAT multi-value returns are first-class — multi-value as both args and
results works.

### Top-level dispatch (per call)

1. If `ppos == |pat|`: success → return `(spos, ncaps)`.
2. If `pat[ppos] == ')'`: close the most recent open capture, recurse
   with `ppos + 1`.
3. If `pat[ppos] == '('`:
   - If `pat[ppos + 1] == ')'`: position capture. Record
     `(spos, -2)`, increment `ncaps`, recurse with `ppos + 2`.
   - Else: substring capture. Record `(spos, -1)`, increment `ncaps`,
     recurse with `ppos + 1`.
4. If `pat[ppos] == '$'` AND `ppos + 1 == |pat|`: succeed iff
   `spos == |sub|`.
5. If `pat[ppos] == '%'` AND `pat[ppos + 1]` is a digit `1..9`:
   back-reference. Look up capture *n*, try to match its bytes
   verbatim at `spos`. On success, recurse with `ppos + 2`.
6. If `pat[ppos] == '%'` AND `pat[ppos + 1] == 'b'`: balanced match.
   Find the balancing close starting at `pat[ppos + 2]` and `pat[ppos + 3]`.
   On success recurse with `ppos + 4`.
7. If `pat[ppos] == '%'` AND `pat[ppos + 1] == 'f'`: frontier.
   Decode the `[set]` at `ppos + 2`. Test prev/curr byte against set
   without consuming. On success recurse with `ppos + set_len`.
8. Otherwise: decode a "matchable" item (literal, `.`, `%X`, `[set]`)
   plus an optional quantifier. Apply the quantifier rule (see below).

### Quantifier handling

After decoding a matchable item at `ppos` ending at `next_ppos`, check
`pat[next_ppos]`:

- `*`: try matching as many of the item as possible, then back off.
- `+`: at least one; consume that, then `*`.
- `-`: try zero first; if the rest of the pattern fails, consume one
  and retry.
- `?`: try with consumption first; if that fails, retry without.
- (no quantifier): match exactly once, recurse.

All four are written as small loops; the recursion is on the rest of
the pattern, not on the current item.

## Pattern-item helpers

```wat
;; Returns 1 if $byte matches the single-char item at $ppos.
(func $match_one_item
  (param $sub_byte i32) (param $pat (ref $LuaArr)) (param $ppos i32)
  (result i32))

;; Returns the pattern position immediately after the item starting
;; at $ppos (literal=+1, %c=+2, [set]=...). Doesn't include the
;; quantifier suffix.
(func $item_end (param $pat (ref $LuaArr)) (param $ppos i32) (result i32))

;; Tests a byte against a [set]. $lpos is the position of the opening
;; '['; the function walks the body to find the matching ']' itself.
(func $match_set
  (param $byte i32) (param $pat (ref $LuaArr))
  (param $lpos i32) (result i32))

;; Tests a byte against a single char class %X (X is the literal letter
;; after '%').
(func $match_class
  (param $byte i32) (param $class_letter i32) (result i32))
```

`$match_class` is a switch:
- `'a' / 'A'` — `isalpha`-like (ASCII)
- `'d' / 'D'` — `'0'..'9'`
- `'s' / 'S'` — `' \t\n\v\f\r'`
- `'w' / 'W'` — `isalnum`-like
- `'x' / 'X'` — `'0'..'9' 'a'..'f' 'A'..'F'`
- `'l' / 'L'`, `'u' / 'U'`, `'p' / 'P'`, `'c' / 'C'`, `'g' / 'G'` —
  the respective ranges
- `'z' / 'Z'` — null byte (`\0`) / non-null
- For uppercase letters X: negated form (`%A` → NOT `%a`).
- For non-class `%X`: literal X (e.g., `%%` → matches `%`).

Implementation: per-bit lookups in inlined ranges. ~50 lines of WAT,
zero allocations.

## Entry points

### `string.find(s, pat, init, plain)`

```
$builtin_string_find:
  s, pat: required
  init:    default 1; negative means from-end; clamp to [1, #s+1]
  plain:   default false

  if plain: byte-walk search for the literal pat in s; return (start,end) or nil.

  anchored = (pat[0] == '^')
  start_ppos = anchored ? 1 : 0
  for sp = init-1 .. #s:
      caps = fresh CapArr
      (end, ncaps) = match_pat(s, sp, pat, start_ppos, caps, 0)
      if end >= 0:
          return (sp+1, end, ...captures...)
      if anchored: break
  return nil
```

Returns 0-based positions converted to 1-based on the way out.

### `string.match(s, pat, init)`

Same scan as `find`, but:
- If `ncaps == 0`: return the matched substring `sub[sp..end-1]`.
- Else: return the captures (each substring capture decoded; position
  captures returned as integers).

### `string.gmatch(s, pat, init)`

Returns a new closure with four upvalues: `(s, pat, cursor, lastmatch)`.
The closure body runs one match attempt from `cursor`, returns the
captures (or whole match), and updates `cursor` and `lastmatch` past
the match. Returns nothing on no-match → the generic-for loop
terminates.

Building a closure from a builtin with upvalues is something the
runtime hasn't needed before. The factory builds a `$LuaClosure` with
a `$UpvalArr` of four boxes manually:

```wat
(struct.new $LuaClosure
  (ref.func $builtin_string_gmatch_iter)
  (array.new_fixed $UpvalArr 4 box_s box_pat box_cursor box_lastmatch))
```

`$builtin_string_gmatch_iter` reads `s` and `pat` from upvalues, reads
`cursor` and `lastmatch`, runs one match, writes back the updated
cursor and lastmatch, returns captures. The `lastmatch` upvalue holds
the end position of the previous accepted match; the iterator rejects
an empty match that falls exactly at `lastmatch` to prevent an infinite
loop on patterns like `"a*"` (the progress guard described in the Risk
section).

### `string.gsub(s, pat, repl, n)`

```
$builtin_string_gsub:
  s, pat, repl: required
  n: default = infinity

  acc = empty byte buffer
  count = 0
  sp = 0

  while sp <= #s and count < n:
      caps = fresh CapArr
      (end, ncaps) = match_pat(s, sp, pat, ...)
      if end < 0:
          break (no more matches from here, but…)
      
      append s[sp..match_start-1] to acc
      replacement = apply_repl(repl, caps, ncaps, s[match_start..end-1])
      append replacement to acc
      count += 1
      sp = end                            ;; advance past the match
      if end == match_start: sp += 1      ;; empty-match progress guard

  append s[sp..#s-1] to acc
  return acc, count
```

Anchored patterns (`^...`) only ever try `sp == 0` for the first
match; after the first match they don't try again. We special-case
this.

#### Repl variants

- **String repl**: scan for `%0..%9` and `%%`; emit captures (or whole
  match for `%0`).
- **Table repl**: index by first capture (or whole match if no
  captures); nil/false ⇒ keep original.
- **Function repl**: call with captures; result must be string or
  number or nil/false; nil/false ⇒ keep original.

Function repl uses the existing `$lua_call` through `call_ref` — same
machinery `table.sort` already uses.

## Implementation order and per-step fixtures

**Status: shipped** (all 9 steps landed in 9 commits; see lessons.md §"When
the design doc held up").

| Step | What | Fixture |
|---|---|---|
| 1 | Helpers: `$match_class`, `$match_set`, `$item_end`. No user-visible behaviour change yet. | none (covered transitively by later steps) |
| 2 | `$match_pat` core: literals, `.`, classes, sets, quantifiers, `^` / `$`. | `tests/fixtures/patterns_find_basic.lua` |
| 3 | Captures (`(...)`, `()`, `%n` back-references). | `tests/fixtures/patterns_captures.lua` |
| 4 | `string.match` entry point. | `tests/fixtures/patterns_match.lua` |
| 5 | `%bxy` and `%f[set]`. | `tests/fixtures/patterns_balanced_frontier.lua` |
| 6 | `string.gmatch`. | `tests/fixtures/patterns_gmatch.lua` |
| 7 | `string.gsub` with string repl. | `tests/fixtures/patterns_gsub_string.lua` |
| 8 | `string.gsub` with table and function repls. | `tests/fixtures/patterns_gsub_repl.lua` |
| 9 | `string.find` plain mode + final polish. | `tests/fixtures/patterns_soak.lua` |

## Out of scope

- UTF-8-aware classes. Lua's pattern classes operate on bytes (ASCII).
  Per the manual: "all classes %x represented by single letters [...]
  follow the C-locale rules". We treat the byte set as ASCII; no
  locale customization.
- `%a` etc. honouring locale.
- Recursive `gsub` repl that returns more captures (Lua converts via
  tostring on the result).
- Pattern caching across calls. Each call re-walks the pattern; the
  cost is bounded by pattern length, which is small.

## Risk register

- **Backtracking pathology.** Catastrophic patterns
  (`(a+)+b` against many `a`s) are possible. Out of scope to defend
  against; we match reference Lua's "trust the user" stance.
- **Multi-value WAT plumbing.** First place in the codebase using
  multi-value WAT returns extensively. Verify Binaryen `wasm-as`
  accepts them (it does; we already use multi-value implicitly via
  `array.new_data` etc.). Verify Node still validates with
  `--experimental-wasm-exnref`.
- **gmatch closure upvalues from a builtin.** Currently all
  user-visible closures have a 0-element upvalue array. The runtime
  type system already permits upvalues on builtin-built closures —
  no new types needed — but this is the first time we exercise it
  from C code in codegen. Smoke-test on step 6 specifically.
- **Empty-match progress guard in gsub/gmatch.** Without the `if end
  == match_start: sp += 1` rule, `gsub(s, ".-", "x")` would loop.
  Land the guard with step 7.

## Acceptance criteria

**Met.** All criteria were satisfied when the milestone closed.

- All four entry points pass against per-step fixtures (manually
  authored corner cases, not derived from reference Lua source). The
  soak fixture (`tests/fixtures/patterns_soak.lua`) exercises every
  pattern feature documented in this doc.
- Performance: matches a 10kB subject against a non-pathological
  pattern in well under a second. (Verified by smoke check.)
- `lessons.md` retro entry added under "When the design doc held up
  (milestone 20, patterns)".

Notable surprises during implementation (detailed in `lessons.md`):
- `i32.and` is not short-circuit in WAT — bit twice (set-range guard in
  step 2, `?`-quantifier sub-read in step 7).
- `%b''` with the same open/close character is undefined by the Lua
  spec; the implementation silently fails to match; fixtures skip it.
- gsub with function repl + string method-call syntax doesn't work
  until string metatables are wired up (separate gap, not a pattern bug).
