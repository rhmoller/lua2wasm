-- math.random / math.randomseed — xoshiro256** PRNG.

-- Determinism: the same seed reproduces the same sequence.
math.randomseed(42)
local a1 = math.random(1, 100)
local a2 = math.random(1, 100)
local a3 = math.random(1, 100)
math.randomseed(42)
local b1 = math.random(1, 100)
local b2 = math.random(1, 100)
local b3 = math.random(1, 100)
print(a1 == b1, a2 == b2, a3 == b3)        -- true   true   true

-- Range bounds are inclusive on both ends.
math.randomseed(1)
local in_range = true
for i = 1, 50 do
  local x = math.random(1, 6)
  if x < 1 or x > 6 then in_range = false end
end
print(in_range)                            -- true

-- 0-arg form returns a float in [0, 1).
math.randomseed(7)
local f = math.random()
print(f >= 0 and f < 1)                   -- true
print(type(f))                            -- number
print(math.type(f))                       -- float

-- 1-arg form: math.random(n) returns an integer in [1, n].
math.randomseed(11)
local g = math.random(10)
print(g >= 1 and g <= 10)                 -- true
print(math.type(g))                       -- integer

-- randomseed returns the seeds it actually used.
print(math.randomseed(123, 456))          -- 123    456

-- math.random(0) returns any 64-bit integer (full-range mode).
math.randomseed(0)
local r = math.random(0)
print(math.type(r))                       -- integer

-- m > n is an error.
local ok = pcall(function() return math.random(10, 1) end)
print(ok)                                  -- false
