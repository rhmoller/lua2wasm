-- __lt and __le — consulted by <, <=, >, >= when the operand types
-- aren't both numbers or both strings.

local function num(x) return type(x) == "table" and x.x or x end
local mt = {
  __lt = function(a, b) return num(a) <  num(b) end,
  __le = function(a, b) return num(a) <= num(b) end,
}
local v = setmetatable({x = 10}, mt)
local w = setmetatable({x = 20}, mt)

-- Between metamethod-bearing values.
print(v < w)             -- true
print(w < v)             -- false
print(v > w)             -- false  (uses __lt: w < v)
print(v <= w)            -- true
print(w >= v)            -- true

-- Cross-type: metamethod still fires.
print(v < 20)            -- true
print(v < 5)             -- false
print(5  < v)            -- true   (metamethod called with (5, v))
print(v >= 10)           -- true
print(v <= 10)           -- true

-- Native paths unchanged.
print(1 < 2)             -- true
print("a" < "b")         -- true
print(2 <= 2)            -- true

-- Missing metamethod → catchable error.
print(pcall(function() return {} < {} end))     -- false   nil
print(pcall(function() return 1 < {} end))      -- false   nil
