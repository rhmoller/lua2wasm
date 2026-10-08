-- String methods through the method cache's string-receiver entry, and the
-- string builtins' fast entries ($LuaFn1, one result) next to their generic
-- ones (all results): optional arguments given as nil, positions far out of
-- range, and the cache noticing a replaced method or __index.

local s = "hello, world"

-- optional integer arguments: nil means absent
print("byte", s:byte(), s:byte(nil), s:byte(2, nil), s:byte(-1), s:byte(100), s:byte(0))
print("byte all", s:byte(1, 3))
print("byte many", select("#", s:byte(1, -1)), s:byte(-3, -1))
print("sub", s:sub(8), s:sub(8, nil), s:sub(-5), s:sub(0), s:sub(3, 2) == "", s:sub(-100, 2))

-- positions beyond 32 bits clamp instead of wrapping
local huge = 1 << 32
print("huge", s:sub(huge), s:sub(1, huge), s:byte(huge + 1), s:sub(-huge, 3), s:sub(huge + 1, -1) == "")

-- the other fast entries
print("len", s:len(), ("x"):rep(3), ("ab"):rep(3, "-"), ("ab"):rep(2, nil), ("ab"):rep(0), ("ab"):rep(-1) == "")
print("rep empty", #(""):rep(1 << 40), #(""):rep(1 << 40, ""))
print("case", s:upper(), ("MiXeD"):lower())
print("char", string.char(), string.char(65), string.char(65, 66, 67, 68), string.char(97, 98, 99, 100, 101))

-- numbers are strings to these functions
local n = 12345
print("numbers", string.byte(n, 2), string.sub(n, 2, 3), string.len(n), string.upper(1.5), string.rep(7, 3))

-- errors still raise
print("errors", pcall(string.rep, "x", 1 << 40), pcall(string.char, 256), pcall(string.sub, "x"),
  pcall(string.byte, {}), (pcall(string.upper)))

-- in a loop the call sites stay cached; a replaced method is seen at once
local sum = 0
for i = 1, #s do sum = sum + s:byte(i) end
print("loop", sum)
local orig = string.upper
local calls = 0
string.upper = function(x) calls = calls + 1; return "UP:" .. x end
local out = {}
for i = 1, 3 do out[i] = ("v" .. i):upper() end
string.upper = orig
print("replaced", table.concat(out, " "), calls, ("back"):upper())

-- a different __index on the string metatable
local mt = getmetatable("")
local lib = mt.__index
mt.__index = {upper = function(x) return "custom " .. x end, byte = lib.byte}
local got = {}
for i = 1, 2 do got[i] = ("z"):upper() end
mt.__index = lib
print("__index", got[1], got[2], ("z"):upper(), ("z"):byte())

-- a table receiver at the same site as a string receiver
local obj = setmetatable({}, {__index = {upper = function(self) return "obj" end}})
local mixed = {}
for _, r in ipairs({"a", obj, "b", obj}) do mixed[#mixed + 1] = r:upper() end
print("mixed", table.concat(mixed, " "))
