-- table.unpack(t [, i [, j]]) — splices t[i..j] as multiple values.

local t = { 10, 20, 30, 40 }

print(table.unpack(t))           -- 10\t20\t30\t40
print(table.unpack(t, 2))        -- 20\t30\t40
print(table.unpack(t, 2, 3))     -- 20\t30

-- Forwarding into a call.
local function sum3(a, b, c) return a + b + c end
print(sum3(table.unpack({ 1, 2, 3 })))     -- 6

-- Capturing into multi-assign.
local a, b, c = table.unpack({ "x", "y", "z" })
print(a, b, c)                   -- x\ty\tz

-- j < i -> no values at the call site, but in mid-arg position Lua
-- still adjusts to 1 value (nil).
print("[", table.unpack(t, 5, 4), "]")  -- [\tnil\t]
