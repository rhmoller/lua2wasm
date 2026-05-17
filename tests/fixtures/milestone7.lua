-- Phase 7: minimal stdlib

print(type(nil))         -- nil
print(type(true))        -- boolean
print(type(42))          -- number
print(type(1.5))         -- number
print(type("hi"))        -- string
print(type({}))          -- table
print(type(print))       -- function

print(tostring(42))      -- "42"
print(tostring(nil))     -- "nil"
print(tostring(true))    -- "true"
print(tostring("hi"))    -- "hi"

print(tonumber("42"))    -- 42
print(tonumber("-7"))    -- -7
print(tonumber(7))       -- 7
print(tonumber("xx"))    -- nil

-- math
print(math.floor(3.7))   -- 3
print(math.floor(-2.3))  -- -3
print(math.abs(-5))      -- 5
print(math.abs(-2.5))    -- 2.5
print(math.sqrt(16))     -- 4.0

-- string
print(string.len("hello"))       -- 5
print(string.sub("hello", 2, 4)) -- "ell"
print(string.sub("hello", 2))    -- "ello"

-- ipairs
local t = {"a", "b", "c"}
for i, v in ipairs(t) do
  print(i)              -- 1, 2, 3
  print(v)              -- a, b, c
end

-- pairs (order matches insertion order due to our linear-probe table)
local p = {}
p.x = 10
p.y = 20
local count = 0
for k, v in pairs(p) do
  count = count + 1
end
print(count)            -- 2
