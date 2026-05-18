-- rawset(t, k, v) — table write that never invokes __newindex.

local t = {}
rawset(t, "a", 1)
rawset(t, "b", 2)
print(t.a, t.b)                  -- 1   2

-- Integer keys.
rawset(t, 1, "one")
rawset(t, 2, "two")
print(t[1], t[2])                -- one   two

-- nil value deletes the entry.
rawset(t, "a", nil)
print(t.a)                       -- nil

-- Returns the table itself, for chaining.
local u = rawset({}, "x", 42)
print(u.x)                       -- 42

-- nil key raises.
local ok = pcall(function() rawset({}, nil, 1) end)
print(ok)                        -- false

-- NaN key raises.
local nan = 0/0
local ok2 = pcall(function() rawset({}, nan, 1) end)
print(ok2)                       -- false

-- Non-table first arg raises.
local ok3 = pcall(function() rawset(42, "x", 1) end)
print(ok3)                       -- false
