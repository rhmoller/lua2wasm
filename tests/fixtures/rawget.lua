-- rawget(t, k) — table read that never invokes __index.

local t = {a = 1, b = 2, [3] = "three"}
print(rawget(t, "a"))         -- 1
print(rawget(t, "b"))         -- 2
print(rawget(t, 3))           -- three
print(rawget(t, "missing"))   -- nil

-- Integer-key arrays.
local arr = {10, 20, 30}
print(rawget(arr, 1))         -- 10
print(rawget(arr, 3))         -- 30
print(rawget(arr, 4))         -- nil

-- The critical property: rawget never fires __index.
local proxy = setmetatable({}, {
  __index = function(_, k) return "via_mm:" .. k end,
})
print(proxy.anything)           -- via_mm:anything   (through __index)
print(rawget(proxy, "anything"))-- nil               (rawget bypasses)

-- Mix: a table with both a real key and an __index. rawget sees only the
-- real key.
local mixed = setmetatable({real = "stored"}, {
  __index = function(_, k) return "fallback:" .. k end,
})
print(mixed.real)                -- stored
print(mixed.other)               -- fallback:other
print(rawget(mixed, "real"))     -- stored
print(rawget(mixed, "other"))    -- nil

-- Non-table first arg raises.
local ok = pcall(function() return rawget(42, "x") end)
print(ok)                        -- false
