-- Milestone 22: error() position prefix + minimal debug library.

-- error(msg) with default level=1 prepends "<src>:<line>: ".
print(pcall(function() error("plain") end))
-- expected: false  error_position:4: plain

-- error(msg, 0) skips the prefix.
print(pcall(function() error("no prefix", 0) end))
-- expected: false  no prefix

-- error(msg, 1) is the default (same as omitting).
print(pcall(function() error("with level 1", 1) end))
-- expected: false  error_position:13: with level 1

-- level=2 points to the call that invoked the function that called error.
local function inner()
  error("two up", 2)
end
local function caller()
  inner()           -- line where error()'s caller was called from = level=2
end
print(pcall(caller))
-- expected: false  error_position:20: two up
-- (line 20 = `  inner()`; level=2 reports the call site of inner.)

-- Non-string errors pass through untouched.
print(pcall(function() error({code = 42}) end))
-- expected: false  table: <...>  (we just verify pcall returns false + a table)
local _, err = pcall(function() error({code = 42}) end)
print(type(err))    -- table
print(err.code)     -- 42

-- assert + error: same prefix applies, since assert calls error with level=2.
-- (Our assert builtin currently uses level 1, so the prefix uses the
-- assert() call site. Document the actual behavior.)
print(pcall(function() assert(false, "asserted") end))

-- debug.traceback returns a string with frames.
local function trace_a()
  return debug.traceback("hi")
end
local function trace_b()
  return trace_a()
end
local tb = trace_b()
-- Verify it has the prefix message and "stack traceback:" line.
print(string.sub(tb, 1, 2))                       -- "hi"
print(string.find(tb, "stack traceback") ~= nil)  -- true

-- debug.getmetatable / debug.setmetatable bypass __metatable.
local t = setmetatable({}, { __metatable = "locked" })
-- Base getmetatable returns "locked"
print(getmetatable(t))                             -- locked
-- debug.getmetatable returns the real metatable
local mt = debug.getmetatable(t)
print(type(mt))                                    -- table
-- And debug.setmetatable replaces it without complaining.
debug.setmetatable(t, { tag = "new" })
print(getmetatable(t))                             -- the new table (no __metatable now)
print(debug.getmetatable(t).tag)                   -- new
