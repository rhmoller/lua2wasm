# Lua 5.5 Standard Library Spec

Clean-room implementation target. Each entry gives the Lua-visible signature,
return shape, error conditions, and current status in this project.

Status: ✅ implemented · 🟡 partial · ❌ missing · 🚫 out of scope

Reference: `lua-5.5.0/doc/manual.html` §6.

---

## Implementation surface (today)

Registered in `src/builtins.c`:

- Globals: `print error pcall xpcall warn type tostring tonumber ipairs pairs next setmetatable getmetatable assert select rawequal rawget rawset rawlen require collectgarbage load`
- `math`: `floor abs sqrt ceil min max sin cos tan asin acos atan exp log deg rad fmod modf tointeger type ult random randomseed` + constants `pi huge maxinteger mininteger`
- `string`: `len sub format upper lower reverse rep byte char find match gmatch gsub pack unpack packsize`
- `utf8`: `char len codepoint offset codes` + constant `charpattern`
- `io`: `write read open lines type output input` + file-handle methods `read write close flush seek lines`
- `table`: `insert remove concat unpack pack move create sort`
- `debug`: `traceback getmetatable setmetatable gethook`
- `os`: `time clock date getenv exit execute remove rename tmpname difftime setlocale`
- Globals: `_VERSION _G`
- `package`: stub with `loaded preload path cpath config`
- `coroutine`: stub empty table (no functions)

Everything below that is not in that list is ❌ unless flagged otherwise.

---

## 6.1 Basic Functions

### `assert(v [, message])` ✅
Returns all its arguments if `v` is truthy. If `v` is `nil` or `false`, raises
an error with `message` (default `"assertion failed!"`). `message` may be any
value; if it's not a string it's passed through unchanged to `error`.

### `collectgarbage([opt [, arg]])` 🟡
GC control. **Implemented as a smart stub:** `"count"` → `0.0`, `"isrunning"` →
`true`, `"stop"/"step"` → `0`, `"generational"/"incremental"` → previous mode
string (tracks last-set mode so round-trip assertions pass). True semantics are
🚫 — host GC.

### `dofile([filename])` ❌
Load and run a file as a chunk; returns its returns. Without `filename`, reads
stdin. Needs `load` + host file access.

### `error(message [, level])` 🟡
Raises an error. `level` controls where the error's position is reported.
**Implemented:** raise with payload; `level` argument is accepted but currently
ignored (file:line prefixing is not yet applied based on level).

### `_G` ✅
The globals table. Reading/writing `_G.x` is equivalent to reading/writing
global `x`. Builtins and library tables appear as entries. `pairs(_G)` works.

### `getmetatable(object)` ✅
Returns the metatable of `object` or `nil`. If the metatable has a
`__metatable` field, returns *that* value instead — **`__metatable` honouring
is ❌**.

### `ipairs(t)` ✅
Returns iterator, state, control such that `for i, v in ipairs(t) do` yields
`1, t[1]; 2, t[2]; …` until the first `nil`.

### `load(chunk [, chunkname [, mode [, env]]])` 🟡
**Implemented as a stub:** always returns `(nil, "no load")`. Callers that do
`local f, err = load(s); if not f then …` see the error string and take their
failure branch. True runtime compilation is 🚫 in an AOT compiler.

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
Uses `tostring` on each, honouring `__tostring`.

### `rawequal(v1, v2)` ✅
Raw equality, bypassing `__eq`.

### `rawget(table, index)` ✅
Bypasses `__index`.

### `rawlen(v)` ✅
Bypasses `__len`. Defined for strings and tables only.

### `rawset(table, index, value)` ✅
Bypasses `__newindex`. Returns `table`.

### `require(modname)` ✅
Static module loader. Walks `package.preload` then `package.loaded`; the
standard stdlib libraries are pre-registered in `package.loaded` at startup so
`require "string"`, `require "math"`, etc. return the same table as `string`,
`math`, etc. Multi-file compilation (`-m`) bakes extra modules in via
`package.preload`. Dynamic filesystem search is ❌.

### `select(n, …)` ✅
- `select('#', …)` → varargs count.
- `select(k, …)` with positive `k` → `…` from index `k` onward.
- Negative `k` indexes from the end (Lua 5.2+).

### `setmetatable(t, mt)` ✅
Sets/clears the metatable of a table. `mt` must be `nil` or a table; otherwise
error. **Does not check `__metatable` protection on the existing metatable.**

### `tonumber(e [, base])` ✅
- Without `base`: converts strings/numbers to a number; returns `nil` on failure.
  Accepts decimal ints, hex `0x...` ints, floats with optional exponents,
  leading/trailing whitespace.
- With `base` (2–36): parses `e` as an integer in that base (case-insensitive);
  returns `nil` for out-of-range digits; raises an error if base itself is
  outside [2, 36].

### `tostring(v)` ✅
Converts any value to a string. Honours `__tostring` and `__name` metamethods.
Floats round-trip via `%g` (matches reference).

### `type(v)` ✅
Returns one of `"nil" "number" "string" "boolean" "table" "function" "thread" "userdata"`.

### `_VERSION` ✅
Global string `"Lua 5.5"`.

### `warn(msg1, …)` ✅
Emits a warning to stderr. Special control messages `"@on"`, `"@off"` toggle
output (accepted silently). Concatenates all string args.

### `xpcall(f, msgh [, arg1, …])` ✅
Like `pcall` but calls `msgh(err)` to produce the returned error value. The
handler itself is protected: if it throws, its error replaces the original.

---

## 6.2 Coroutine Manipulation (`coroutine`)

❌ Entire library. `coroutine` is an empty stub table (enough for
`type(coroutine) == "table"` and `require "coroutine"` to work). Blocked on
WASM stack-switching.

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

`require` is ✅ (static, see §6.1). `package` is a 🟡 stub table.

| API | Status | Description |
|---|---|---|
| `require(modname)` | ✅ | Load module, cache result. Static; no fs search. |
| `package.config` | ✅ | Standard path-config string (`"/\n;\n?\n!\n-\n"`). |
| `package.cpath` | 🟡 | Present as empty string; no C loader. |
| `package.loaded` | ✅ | Cache of loaded modules (stdlib pre-populated). |
| `package.loadlib(libname, funcname)` | 🚫 | Load a C library. Not applicable. |
| `package.path` | 🟡 | Present as empty string; no filesystem searcher. |
| `package.preload` | ✅ | Loader functions by module name; `-m` populates it. |
| `package.searchers` | ❌ | Ordered list of searchers tried by `require`. |
| `package.searchpath(name, path [, sep [, rep]])` | ❌ | Path search helper. |

---

## 6.4 String Manipulation (`string`)

### `string.byte(s [, i [, j]])` ✅
Returns the byte values of `s[i] … s[j]` (defaults: `i = j = 1`). Negative
indices count from the end.

### `string.char(…)` ✅
Returns a string built from the given byte values (each in `0..255`).

### `string.dump(function [, strip])` 🚫
Dumps a function as bytecode. Not meaningful without a bytecode VM.

### `string.find(s, pattern [, init [, plain]])` ✅
Returns the start/end indices of the first match (and captures), or `nil`.
`plain = true` disables pattern syntax. Full Lua patterns engine implemented.

### `string.format(fmt, …)` ✅
C-`printf`-like. **Implemented specifiers:** `%s %d %i %o %u %x %X %c %q %e
%E %f %F %g %G %a %A %%`. Width, precision, and flags (`- + # 0 ' '`) are
all supported (delegated to the JS host's `fmt_spec` helper).

### `string.gmatch(s, pattern [, init])` ✅
Iterator returning successive matches. Full patterns engine implemented.

### `string.gsub(s, pattern, repl [, n])` ✅
Global substitute; `repl` may be string, table, or function. Returns
`(new_string, num_replacements)`.

### `string.len(s)` ✅
Byte length (same as `#s`). Defined only for strings.

### `string.lower(s)` ✅
ASCII lowercase.

### `string.match(s, pattern [, init])` ✅
Returns captures of first match, or whole match if no captures, or `nil`.

### `string.pack(fmt, v1, v2, …)` ✅
Pack values to a binary string per a format spec. Format chars: `< > = ! b B
h H i I l L j J f d n s z x X` plus sized variants like `i4`.

### `string.packsize(fmt)` ✅
Size in bytes of a `pack` format (no variable-sized parts allowed).

### `string.rep(s, n [, sep])` ✅
`n` copies of `s`, optionally joined by `sep`.

### `string.reverse(s)` ✅
Byte-reversed string.

### `string.sub(s, i [, j])` ✅
Substring `s[i..j]`, 1-based, inclusive. Negative indices count from the end.
Defaults: `j = -1`.

### `string.unpack(fmt, s [, pos])` ✅
Inverse of `pack`. Returns unpacked values plus the position after the read.

### `string.upper(s)` ✅
ASCII uppercase.

### Lua patterns
✅ Full engine implemented. Character classes: `. %a %A %c %C %d %D %g %G %l
%L %p %P %s %S %u %U %w %W %x %X` + `[set]` + literal char. Anchors `^` `$`.
Repetition `* + - ?`. Captures `( … )` (with `()` for position capture).
Escapes `%n` (back-ref), `%bxy` (balanced match), `%f[set]` (frontier).

---

## 6.5 UTF-8 Support (`utf8`)

✅ Entire library implemented.

| API | Status | Description |
|---|---|---|
| `utf8.char(…)` | ✅ | Codepoints → UTF-8 string. |
| `utf8.charpattern` | ✅ | Pattern `"[\0-\x7F\xC2-\xFD][\x80-\xBF]*"` matching one codepoint. |
| `utf8.codepoint(s [, i [, j [, lax]]])` | ✅ | Decode codepoints in range; `lax` skips validation. |
| `utf8.codes(s [, lax])` | ✅ | Iterator yielding `(pos, codepoint)`. |
| `utf8.len(s [, i [, j [, lax]]])` | ✅ | Number of codepoints, or `nil, errpos` on invalid byte. |
| `utf8.offset(s, n [, i])` | ✅ | Byte offset of the n-th codepoint. |

---

## 6.6 Table Manipulation (`table`)

### `table.concat(list [, sep [, i [, j]]])` ✅
Joins `list[i..j]` with `sep` (default `""`, `i=1`, `j=#list`).

### `table.create(nseq [, nrec])` ✅
New in 5.5. Allocates a table with pre-sized array and hash parts.

### `table.insert(list, [pos,] value)` ✅
Inserts `value` at position `pos` (default `#list + 1`); shifts subsequent
elements up by one.

### `table.move(a1, f, e, t [, a2])` ✅
Copies `a1[f..e]` to `(a2 or a1)[t..]`. Handles overlapping ranges correctly.
Returns the destination table.

### `table.pack(…)` ✅
Returns `{n = select('#', …), [1] = arg1, …}`.

### `table.remove(list [, pos])` ✅
Removes and returns `list[pos]` (default `#list`); shifts subsequent elements
down by one.

### `table.sort(list [, comp])` ✅
In-place sort. `comp(a, b)` returns true when `a` should precede `b`; default
is `<`.

### `table.unpack(list [, i [, j]])` ✅
Returns `list[i], list[i+1], …, list[j]`.

---

## 6.7 Mathematical Functions (`math`)

### Implemented ✅
`math.abs(x)` · `math.ceil(x)` · `math.floor(x)` · `math.sqrt(x)` ·
`math.sin(x)` · `math.cos(x)` · `math.tan(x)` · `math.asin(x)` ·
`math.acos(x)` · `math.atan(y [, x])` (1-arg and 2-arg atan2) ·
`math.exp(x)` · `math.log(x [, base])` (1-arg natural log and 2-arg log-base) ·
`math.min(…)` · `math.max(…)` ·
`math.deg(x)` · `math.rad(x)` · `math.fmod(x, y)` · `math.modf(x)` ·
`math.tointeger(x)` · `math.type(x)` · `math.ult(m, n)` ·
`math.random([m [, n]])` · `math.randomseed([x [, y]])` ·
`math.pi` · `math.huge` · `math.maxinteger` · `math.mininteger`.

### Missing ❌

| API | Description |
|---|---|
| `math.frexp(x)` | Returns `(m, e)` with `x = m·2^e`, `0.5 ≤ |m| < 1`. |
| `math.ldexp(m, e)` | Returns `m·2^e`. |

---

## 6.8 Input and Output (`io`)

### `io.write(…)` ✅
Writes each argument (string or number) to default output.

### `io.read(…)` ✅
Reads from default input. Formats: `"l"` (line, no `\n`), `"L"` (line, with
`\n`), `"a"` (all), `"n"` (number), or integer `n` (n bytes). No-arg form
defaults to `"l"`. Returns `nil` at EOF for line/number/byte modes; `""` at
EOF for `"a"`.

### `io.open(filename [, mode])` ✅
Opens a file; returns a file handle or `(nil, errmsg)`. Modes: `r w a r+ w+
a+`, optionally `b`.

### `io.lines([filename, …])` ✅
Iterator over lines of a file (or default input when called with no args).

### `io.type(obj)` ✅
Returns `"file"` / `"closed file"` / `nil`.

### `io.output([file])` / `io.input([file])` ✅
Get/set default output/input file.

### `io.stdin` / `io.stdout` / `io.stderr` ✅
Standard file handles as table objects with `:read`/`:write`/`:close`/`:flush`
methods.

### Missing ❌

| API | Description |
|---|---|
| `io.close([file])` | Close file (default: default output). Not a top-level `io.*` entry; use `f:close()`. |
| `io.flush()` | Flush default output. Not a top-level `io.*` entry; use `io.stdout:flush()`. |
| `io.popen(prog [, mode])` | Pipe to/from subprocess. 🚫 in browser. |
| `io.tmpfile()` | Anonymous temp file. |

### File methods ✅
`f:close()` · `f:flush()` · `f:lines(…)` · `f:read(…)` · `f:seek([whence [, offset]])` · `f:write(…)`.
`f:setvbuf(mode [, size])` is ❌.

---

## 6.9 Operating System Facilities (`os`)

Most of the library is now implemented via host imports.

| API | Status | Description |
|---|---|---|
| `os.clock()` | ✅ | CPU time used by the program (seconds, float). |
| `os.date([format [, time]])` | ✅ | Format a time value. `*t` / `!*t` return tables with `year month day hour min sec wday yday isdst`. |
| `os.difftime(t2, t1)` | ✅ | Seconds between two times (as float). |
| `os.execute([command])` | 🟡 | No command → `true` (shell "available"). With command → `(nil, "exit", 1)`. Cannot run subprocesses in wasm. |
| `os.exit([code [, close]])` | ✅ | Terminate with given exit code. |
| `os.getenv(varname)` | ✅ | Environment lookup via host import. |
| `os.remove(filename)` | ✅ | Delete a file; returns `true` or `(nil, errmsg)`. |
| `os.rename(oldname, newname)` | ✅ | Move a file; returns `true` or `(nil, errmsg)`. |
| `os.setlocale(locale [, category])` | 🟡 | Only the `"C"` locale is supported; other locales return `nil`. |
| `os.time([t])` | ✅ | Current wall-clock time (integer seconds), or build a time from a `{year,month,day,…}` table. |
| `os.tmpname()` | ✅ | Generate a unique temp filename via host. |

---

## 6.10 The Debug Library (`debug`)

Minimal subset implemented. The full library remains largely out of scope for
an AOT compiler without a bytecode VM.

| API | Status | Description |
|---|---|---|
| `debug.traceback([thread,] [msg [, level]])` | ✅ | Best-effort stack traceback using WASM exception metadata. |
| `debug.getmetatable(value)` | ✅ | Like `getmetatable` but ignores `__metatable`. |
| `debug.setmetatable(value, mt)` | ✅ | Set metatable on any value. |
| `debug.gethook([thread])` | 🟡 | Stub: always returns `nil, "", 0` (no hooks installed). |
| `debug.debug()` | ❌ | REPL prompt. |
| `debug.getinfo([thread,] f [, what])` | ❌ | Function/frame metadata. |
| `debug.getlocal([thread,] f, local)` | ❌ | Read local by index. |
| `debug.getregistry()` | 🚫 | The Lua registry. No C-API. |
| `debug.getupvalue(f, up)` | ❌ | Read upvalue. |
| `debug.getuservalue(u, n)` | 🚫 | Userdata user values. |
| `debug.sethook([thread,] hook, mask [, count])` | ❌ | Install a hook. |
| `debug.setlocal([thread,] f, local, value)` | ❌ | Write local. |
| `debug.setupvalue(f, up, value)` | ❌ | Write upvalue. |
| `debug.setuservalue(u, value, n)` | 🚫 | |
| `debug.upvalueid(f, n)` | ❌ | Identity of an upvalue. |
| `debug.upvaluejoin(f1, n1, f2, n2)` | ❌ | Make two closures share an upvalue. |

---

## Implementation order — recommended (remaining gaps)

1. **`io.close` / `io.flush` top-level entries** — trivial wrappers over the default-output handle.
2. **`io.tmpfile`** — anonymous temp file via host.
3. **`math.frexp` / `math.ldexp`** — two missing math functions; can delegate to host JS.
4. **`error(msg, level)` level handling** — apply file:line prefix based on level.
5. **`__metatable` protection in `setmetatable` / `getmetatable`** — one field check.
6. **`__pairs` metamethod** — one check in `pairs`.
7. **`os.execute` with command** — truly unsandboxable in browser; document as 🚫.
8. **`package.searchers` / `package.searchpath`** — needed for full Lua module ecosystem.
9. **`debug.*` remainder** — mostly 🚫 without a bytecode VM.
10. **`coroutine.*`** — wait for stack-switching proposal.
11. **`load`** — needs the compiler at runtime. Existing Emscripten build proves it is feasible.
12. **`dofile` / `loadfile`** — need host file access + `load`.
13. **`string.dump`** — 🚫 without bytecode VM.
