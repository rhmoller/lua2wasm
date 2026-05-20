-- Filesystem round-trip: io.open, file:write/read/seek/close, io.lines,
-- io.type, os.rename, os.remove. The driver supplies a unique temp path
-- via LUA2WASM_TEST_FILE so concurrent runs don't collide, and all
-- printed values are kept deterministic (no machine-specific paths).
local path  = os.getenv("LUA2WASM_TEST_FILE")
local path2 = path .. ".renamed"

-- write a few lines, including a multi-arg write
local f = assert(io.open(path, "w"))
f:write("line1\n")
f:write("line2\n", "line3\n")
assert(f:close())

-- read a line, then slurp the rest
local g = assert(io.open(path, "r"))
print(g:read("l"))            -- line1
local rest = g:read("a")
print(#rest)                  -- 12  ("line2\nline3\n")
g:close()

-- byte count + seek
local s = assert(io.open(path, "r"))
print(s:read(5))              -- line1
print(s:seek("set", 0))       -- 0
print(s:read("l"))            -- line1
print(s:seek())               -- 6  (cursor after "line1\n")
s:close()

-- line iterator
for line in io.lines(path) do print("L:" .. line) end

-- handle introspection
local h = assert(io.open(path, "r"))
print(io.type(h))             -- file
h:close()
print(io.type(h))             -- closed file
print(io.type({}))            -- nil

-- opening a missing file fails softly
local ok, err = io.open(path .. ".nope", "r")
print(ok, err ~= nil)         -- nil  true

-- rename then remove
assert(os.rename(path, path2))
local gone = io.open(path, "r")   -- single local truncates to first return
print(gone)                       -- nil  (gone after rename)
assert(os.remove(path2))
print("done")
