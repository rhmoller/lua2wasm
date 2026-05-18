# Lua 5.5 Standard Library Spec

Clean-room implementation target. Each entry gives the Lua-visible signature,
return shape, error conditions, and current status in this project.

Status: ✅ implemented · 🟡 partial · ❌ missing · 🚫 out of scope

Reference: `lua-5.5.0/doc/manual.html` §6.

---

## Implementation surface (today)

Registered in `src/builtins.c`:

- Globals: `print error pcall type tostring tonumber ipairs pairs next setmetatable getmetatable assert select`
- `math`: `floor abs sqrt ceil min max sin cos tan asin acos atan exp log` + constants `pi huge`
- `string`: `len sub format`
- `io`: `write read`
- `table`: `insert remove concat unpack`
- Globals: `_VERSION`

Everything below that is not in that list is ❌ unless flagged otherwise.

---

## 6.1 Basic Functions

### `assert(v [, message])` ✅
Returns all its arguments if `v` is truthy. If `v` is `nil` or `false`, raises
an error with `message` (default `"assertion failed!"`). `message` may be any
value; if it's not a string it's passed through unchanged to `error`.

### `collectgarbage([opt [, arg]])` ❌
GC control. Options: `"collect" "stop" "restart" "count" "step" "isrunning"
"incremental" "generational" "param"`. **Recommended:** implement as a no-op
returning sensible defaults (`"count"` → `0`, `"isrunning"` → `true`) so
programs that defensively call it don't crash. True semantics are 🚫 — host GC.

### `dofile([filename])` ❌
Load and run a file as a chunk; returns its returns. Without `filename`, reads
stdin. Needs `load` + host file access.

### `error(message [, level])` 🟡
Raises an error. `level` controls where the error's position is reported.
**Implemented:** raise with payload. **Missing:** `level` argument, file:line
prefixing of string messages.

### `_G` ❌
The globals table. Reading/writing `_G.x` should be equivalent to reading/
writing global `x`. Requires reifying the global environment as a table —
currently globals live in WASM globals slots.

### `getmetatable(object)` ✅
Returns the metatable of `object` or `nil`. If the metatable has a
`__metatable` field, returns *that* value instead — **`__metatable` honouring
is ❌**.

### `ipairs(t)` ✅
Returns iterator, state, control such that `for i, v in ipairs(t) do` yields
`1, t[1]; 2, t[2]; …` until the first `nil`.

### `load(chunk [, chunkname [, mode [, env]]])` ❌
Compiles and returns a function. `chunk` is a string or a function returning
string chunks (until `nil` or empty). `mode` ∈ `"b" "t" "bt"` selects binary /
text. Returns `nil, errmsg` on syntax error. **Implementing this requires the
compiler at runtime** (the Emscripten playground build already proves this is
feasible).

### `loadfile([filename [, mode [, env]]])` ❌
Like `load` but reads from a file. Needs host file access.

### `next(table [, index])` ✅
Iterator primitive. Returns the next key-value pair or `nil`. Order is
unspecified across `next` calls but stable within one traversal as long as the
table is not mutated structurally.

### `pairs(t)` ✅
Returns `next, t, nil` (or, if `__pairs` is defined, the result of calling it).
**`__pairs` metamethod is ❌**.

### `pcall(f [, arg1, …])` ✅
Calls `f(arg1, …)` in protected mode. Returns `true, …` on success or
`false, err` on error. Implemented via WASM `try_table` catching `$LuaError`.

### `print(…)` ✅
Writes each argument to stdout, separated by tabs, with a trailing newline.
Uses `tostring` on each. **Does not honour `__tostring`** because `tostring`
itself doesn't yet.

### `rawequal(v1, v2)` ❌
Raw equality, bypassing `__eq`. Cheap: just the existing eq path with the
metamethod check skipped.

### `rawget(table, index)` ❌
Bypasses `__index`. Cheap.

### `rawlen(v)` ❌
Bypasses `__len`. Defined for strings and tables only.

### `rawset(table, index, value)` ❌
Bypasses `__newindex`. Returns `table`. Index must not be `nil` or `NaN`.

### `require(modname)` ❌
Module loader. Searches `package.searchers`, caches in `package.loaded`. Whole
machinery is ❌.

### `select(n, …)` ✅
- `select('#', …)` → varargs count.
- `select(k, …)` with positive `k` → `…` from index `k` onward.
- Negative `k` indexes from the end (Lua 5.2+).

### `setmetatable(t, mt)` ✅
Sets/clears the metatable of a table. `mt` must be `nil` or a table; otherwise
error. **Does not check `__metatable` protection on the existing metatable.**

### `tonumber(e [, base])` 🟡
- Without `base`: converts strings/numbers to a number; returns `nil` on failure.
- With `base` (2–36): parses `e` as an integer in that base; ❌.

### `tostring(v)` 🟡
Converts any value to a string. **Missing:** `__tostring` and `__name`
metamethod support; floats currently round-trip via `%g` (matches reference).

### `type(v)` ✅
Returns one of `"nil" "number" "string" "boolean" "table" "function" "thread" "userdata"`.

### `_VERSION` ✅
Global string `"Lua 5.5"`.

### `warn(msg1, …)` ❌
Emits a warning. Special control messages `"@on"`, `"@off"` toggle output.
Concatenates all string args.

### `xpcall(f, msgh [, arg1, …])` ❌
Like `pcall` but calls `msgh(err)` to produce the returned error value, with
the original stack still live (so tracebacks can be captured).

---

## 6.2 Coroutine Manipulation (`coroutine`)

❌ Entire library. Blocked on WASM stack-switching.

| API | Description |
|---|---|
| `coroutine.create(f)` | New coroutine wrapping `f` (suspended). |
| `coroutine.close(co)` | Closes a coroutine (runs `__close` of pending values). |
| `coroutine.isyieldable([co])` | Whether the coroutine can yield. |
| `coroutine.resume(co, …)` | Resumes; returns `true, vals…` or `false, err`. |
| `coroutine.running()` | Current coroutine + boolean "is main". |
| `coroutine.status(co)` | `"running" "suspended" "normal" "dead"`. |
| `coroutine.wrap(f)` | Like `create` but returns a function that resumes it. |
| `coroutine.yield(…)` | Suspends current coroutine. |

---

## 6.3 Modules (`require`, `package`)

❌ Entire system.

| API | Description |
|---|---|
| `require(modname)` | Load module, cache result. |
| `package.config` | Path-config string. |
| `package.cpath` | C-loader search path. |
| `package.loaded` | Cache of loaded modules. |
| `package.loadlib(libname, funcname)` | Load a C library. 🚫 not applicable. |
| `package.path` | Lua-loader search path. |
| `package.preload` | Loader functions by module name. |
| `package.searchers` | Ordered list of searchers tried by `require`. |
| `package.searchpath(name, path [, sep [, rep]])` | Path search helper. |

**Recommended scope cut**: implement a *static* `require` that resolves at
compile time against a fixed set of module names baked into the wasm.

---

## 6.4 String Manipulation (`string`)

### `string.byte(s [, i [, j]])` ❌
Returns the byte values of `s[i] … s[j]` (defaults: `i = j = 1`). Negative
indices count from the end.

### `string.char(…)` ❌
Returns a string built from the given byte values (each in `0..255`).

### `string.dump(function [, strip])` 🚫
Dumps a function as bytecode. Not meaningful without a bytecode VM.

### `string.find(s, pattern [, init [, plain]])` ❌
Returns the start/end indices of the first match (and captures), or `nil`.
`plain = true` disables pattern syntax. **Needs Lua patterns engine.**

### `string.format(fmt, …)` 🟡
C-`printf`-like. **Implemented specifiers:** `%s %d %x %g %f %e %%`, optional
`.N` precision. **Missing:** width, flags (`- + # 0 ' '`), `%i %o %u %X %c %q
%a %A`.

### `string.gmatch(s, pattern [, init])` ❌
Iterator returning successive matches. Needs patterns.

### `string.gsub(s, pattern, repl [, n])` ❌
Global substitute; `repl` may be string, table, or function. Returns
`(new_string, num_replacements)`. Needs patterns.

### `string.len(s)` ✅
Byte length (same as `#s`). Defined only for strings.

### `string.lower(s)` ❌
ASCII lowercase (locale-aware in reference Lua — we'd ship ASCII-only).

### `string.match(s, pattern [, init])` ❌
Returns captures of first match, or whole match if no captures, or `nil`.

### `string.pack(fmt, v1, v2, …)` ❌
Pack values to a binary string per a format spec. Format chars: `<>=!  b B h H i I l L j J f d n s z x X` plus integer-sized variants like `i4`. ~500 lines in reference.

### `string.packsize(fmt)` ❌
Size in bytes of a `pack` format (no variable-sized parts allowed).

### `string.rep(s, n [, sep])` ❌
`n` copies of `s`, optionally joined by `sep`.

### `string.reverse(s)` ❌
Byte-reversed string.

### `string.sub(s, i [, j])` ✅
Substring `s[i..j]`, 1-based, inclusive. Negative indices count from the end.
Defaults: `j = -1`.

### `string.unpack(fmt, s [, pos])` ❌
Inverse of `pack`. Returns unpacked values plus the position after the read.

### `string.upper(s)` ❌
ASCII uppercase.

### Lua patterns (sub-spec for find/match/gmatch/gsub)
Character classes: `. %a %A %c %C %d %D %g %G %l %L %p %P %s %S %u %U %w %W %x %X` + `[set]` + literal char. Anchors `^` `$`. Repetition `* + - ?`. Captures `( … )` (with `()` for position capture). Escapes `%n` (back-ref), `%bxy` (balanced match), `%f[set]` (frontier). The pattern engine in `lstrlib.c` is ~400 lines; a faithful clean-room version is the single largest stdlib item.

---

## 6.5 UTF-8 Support (`utf8`)

❌ Entire library. ~150 lines in reference.

| API | Description |
|---|---|
| `utf8.char(…)` | Codepoints → UTF-8 string. |
| `utf8.charpattern` | Pattern `"[\0-\x7F\xC2-\xFD][\x80-\xBF]*"` matching one codepoint. |
| `utf8.codepoint(s [, i [, j [, lax]]])` | Decode codepoints in range; `lax` skips validation. |
| `utf8.codes(s [, lax])` | Iterator yielding `(pos, codepoint)`. |
| `utf8.len(s [, i [, j [, lax]]])` | Number of codepoints, or `nil, errpos` on invalid byte. |
| `utf8.offset(s, n [, i])` | Byte offset of the n-th codepoint. |

---

## 6.6 Table Manipulation (`table`)

### `table.concat(list [, sep [, i [, j]]])` ✅
Joins `list[i..j]` with `sep` (default `""`, `i=1`, `j=#list`).

### `table.create(nseq [, nrec])` ❌
New in 5.5. Allocates a table with pre-sized array and hash parts. We can
honour by pre-sizing internal arrays.

### `table.insert(list, [pos,] value)` ✅
Inserts `value` at position `pos` (default `#list + 1`); shifts subsequent
elements up by one.

### `table.move(a1, f, e, t [, a2])` ❌
Copies `a1[f..e]` to `(a2 or a1)[t..]`. Handles overlapping ranges correctly.
Returns the destination table.

### `table.pack(…)` ❌
Returns `{n = select('#', …), [1] = arg1, …}`.

### `table.remove(list [, pos])` ✅
Removes and returns `list[pos]` (default `#list`); shifts subsequent elements
down by one.

### `table.sort(list [, comp])` ❌
In-place sort. `comp(a, b)` returns true when `a` should precede `b`; default
is `<`. Reference uses introspection-aware quicksort.

### `table.unpack(list [, i [, j]])` ✅
Returns `list[i], list[i+1], …, list[j]`.

---

## 6.7 Mathematical Functions (`math`)

### Implemented ✅
`math.abs(x)` · `math.ceil(x)` · `math.floor(x)` · `math.sqrt(x)` ·
`math.sin(x)` · `math.cos(x)` · `math.tan(x)` · `math.asin(x)` ·
`math.acos(x)` · `math.atan(y [, x])` (currently 1-arg only — verify) ·
`math.exp(x)` · `math.log(x [, base])` (currently 1-arg only — verify) ·
`math.min(…)` · `math.max(…)` · `math.pi` · `math.huge`.

### Missing ❌

| API | Description |
|---|---|
| `math.deg(x)` | Radians → degrees. |
| `math.rad(x)` | Degrees → radians. |
| `math.fmod(x, y)` | `x - trunc(x/y)*y` (truncating, not floor). |
| `math.modf(x)` | Returns `(integral_part, fractional_part)` as floats. |
| `math.frexp(x)` | Returns `(m, e)` with `x = m·2^e`, `0.5 ≤ |m| < 1`. |
| `math.ldexp(m, e)` | Returns `m·2^e`. |
| `math.maxinteger` | `9223372036854775807`. |
| `math.mininteger` | `-9223372036854775808`. |
| `math.random([m [, n]])` | No args: `[0,1)`. `m`: `[1,m]`. `m,n`: `[m,n]`. Reference uses xoshiro256**. |
| `math.randomseed([x [, y]])` | Seeds the PRNG; returns the seed pair used. |
| `math.tointeger(x)` | Convert to integer if exact; else `nil`. |
| `math.type(x)` | `"integer"` / `"float"` / `nil`. |
| `math.ult(m, n)` | Unsigned integer less-than. |
| `math.atan(y, x)` second arg | Two-arg form (atan2). |
| `math.log(x, base)` second arg | log base `base`. |

---

## 6.8 Input and Output (`io`)

### `io.write(…)` ✅
Writes each argument (string or number) to default output.

### `io.read(…)` 🟡
Reads from default input. Formats: `"l"` (line, no `\n`), `"L"` (line, with
`\n`), `"a"` (all), `"n"` (number), or integer `n` (n bytes). **Implemented:**
line-only. **Missing:** other formats + multiple formats per call.

### Missing ❌

| API | Description |
|---|---|
| `io.open(filename [, mode])` | Open file; returns file handle or `nil, errmsg`. Modes: `r w a r+ w+ a+`, optionally `b`. |
| `io.close([file])` | Close file (default: default output). |
| `io.flush()` | Flush default output. |
| `io.input([file])` / `io.output([file])` | Get/set default input/output. |
| `io.lines([filename, …])` | Iterator over lines. |
| `io.popen(prog [, mode])` | Pipe to/from subprocess. 🚫 unlikely in browser. |
| `io.stderr` `io.stdin` `io.stdout` | Standard file handles. |
| `io.tmpfile()` | Anonymous temp file. |
| `io.type(obj)` | `"file"` / `"closed file"` / `nil`. |

### File methods ❌
`f:close() f:flush() f:lines(…) f:read(…) f:seek([whence [, offset]])
f:setvbuf(mode [, size]) f:write(…)`.

---

## 6.9 Operating System Facilities (`os`)

❌ Entire library. Most entries need a host capability layer.

| API | Description |
|---|---|
| `os.clock()` | CPU time used by the program (seconds, float). |
| `os.date([format [, time]])` | Format a time value. `*t` / `!*t` return tables. |
| `os.difftime(t2, t1)` | Seconds between two times. |
| `os.execute([command])` | Shell out. 🚫 in browser. |
| `os.exit([code [, close]])` | Terminate. |
| `os.getenv(varname)` | Environment lookup. |
| `os.remove(filename)` | Delete a file. |
| `os.rename(oldname, newname)` | Move a file. |
| `os.setlocale(locale [, category])` | Set locale. |
| `os.time([t])` | Current time, or build a time from a table. |
| `os.tmpname()` | Generate a unique temp filename. |

**Browser-friendly subset to implement first:** `os.clock`, `os.time`,
`os.difftime`, `os.date` (date formatting is pure-ish), `os.getenv` (host
provides). Files and exec are harder.

---

## 6.10 The Debug Library (`debug`)

❌ Entire library — and largely out of scope for an AOT compiler without a
bytecode VM.

| API | Description |
|---|---|
| `debug.debug()` | REPL prompt. |
| `debug.gethook([thread])` | Current hook. |
| `debug.getinfo([thread,] f [, what])` | Function/frame metadata. |
| `debug.getlocal([thread,] f, local)` | Read local by index. |
| `debug.getmetatable(value)` | Like `getmetatable` but ignores `__metatable`. ✅ feasible. |
| `debug.getregistry()` | The Lua registry. 🚫 no C-API. |
| `debug.getupvalue(f, up)` | Read upvalue. |
| `debug.getuservalue(u, n)` | Userdata user values. 🚫. |
| `debug.sethook([thread,] hook, mask [, count])` | Install a hook. |
| `debug.setlocal([thread,] f, local, value)` | Write local. |
| `debug.setmetatable(value, mt)` | Set metatable on any value. |
| `debug.setupvalue(f, up, value)` | Write upvalue. |
| `debug.setuservalue(u, value, n)` | 🚫. |
| `debug.traceback([thread,] [msg [, level]])` | Stack traceback. |
| `debug.upvalueid(f, n)` | Identity of an upvalue. |
| `debug.upvaluejoin(f1, n1, f2, n2)` | Make two closures share an upvalue. |

**Realistic subset:** `debug.traceback` (best-effort, using WASM exception
metadata), `debug.getmetatable`, `debug.setmetatable`.

---

## Implementation order — recommended

Smallest leverage → largest:

1. **`raw{equal,get,set,len}`** (4 trivial primitives).
2. **`table.{pack, unpack, move, create}`** — table-only, no patterns.
3. **`string.{upper, lower, rep, reverse, byte, char}`** — pure-bytes.
4. **`math` fillers**: `deg, rad, fmod, modf, tointeger, type, maxinteger, mininteger, ult`; second arg of `atan`/`log`.
5. **`math.random` / `math.randomseed`** — xoshiro256** like reference.
6. **`utf8.*`** — six entries, ~150 lines total.
7. **Finish `string.format`** — width, flags, missing specifiers, `%q`.
8. **Finish `io.read`** — all formats.
9. **`table.sort`** — quicksort with comparator callback through `call_ref`.
10. **`tostring`/`print` honour `__tostring`**; `tonumber` accepts `base`.
11. **`xpcall`, `error(msg, level)`, `warn`, `_G`, `rawget`/`rawset` already done in step 1.**
12. **Lua patterns** — `string.{find, match, gmatch, gsub}`. Biggest single item; needs its own design doc and test suite.
13. **`string.pack` / `string.unpack` / `string.packsize`** — second biggest.
14. **`io.open` + file methods** behind a host capability (Node `fs`, browser File API / OPFS).
15. **`os.{clock, time, difftime, date, getenv}`** behind clock + env imports. `os.exit` last.
16. **`load`** — needs the compiler at runtime. Existing Emscripten build proves it.
17. **`require` / `package.*`** — static module table baked at compile time.
18. **`debug.{traceback, getmetatable, setmetatable}`** — minimal subset.
19. **`coroutine.*`** — wait for stack-switching proposal.

Items 1–8 are roughly an afternoon each and close the majority of "I tried to
run a normal-looking Lua program and it broke" gaps.
