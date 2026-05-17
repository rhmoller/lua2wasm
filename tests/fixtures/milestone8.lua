-- Phase 8: metatables

-- __index table chain (classic OOP-style inheritance)
local Animal = {}
Animal.kind = "animal"
local function Animal_speak(self) return self.kind .. " speaks" end
-- No method-call (`:`) sugar yet; pass self explicitly.
Animal.speak = Animal_speak

local Dog = {}
Dog.kind = "dog"
setmetatable(Dog, {__index = Animal})

print(Dog.kind)               -- "dog" (own)
print(Dog.speak(Dog))         -- "dog speaks" (inherited via __index)

-- __index function form
local fallback_meta = {__index = function(t, k) return "default:" .. k end}
local t = setmetatable({}, fallback_meta)
t.real = "hello"
print(t.real)                 -- "hello"
print(t.missing)              -- "default:missing"

-- __add metamethod
local Vec = {}
Vec.__add = function(a, b)
  return setmetatable({x = a.x + b.x, y = a.y + b.y}, Vec)
end
local v1 = setmetatable({x = 1, y = 2}, Vec)
local v2 = setmetatable({x = 10, y = 20}, Vec)
local v3 = v1 + v2
print(v3.x)                   -- 11
print(v3.y)                   -- 22

-- __eq: tables compare equal when their .id fields match
local IdEq = {__eq = function(a, b) return a.id == b.id end}
local a = setmetatable({id = 42}, IdEq)
local b = setmetatable({id = 42}, IdEq)
local c = setmetatable({id = 99}, IdEq)
print(a == b)                 -- true
print(a == c)                 -- false

-- getmetatable
local mt = getmetatable(Dog)
print(type(mt))               -- "table"
print(getmetatable({}))       -- nil
