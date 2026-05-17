-- Phase 4: tables

-- positional constructor
local a = {10, 20, 30}
print(a[1])           -- 10
print(a[2])           -- 20
print(a[3])           -- 30
print(#a)             -- 3

-- named constructor + field access
local p = {name = "alice", age = 30}
print(p.name)         -- alice
print(p.age)          -- 30

-- mixed constructor
local m = {100, 200, x = "ex"}
print(m[1])           -- 100
print(m[2])           -- 200
print(m.x)            -- ex

-- assignment to existing key (update)
p.age = 31
print(p.age)          -- 31

-- assignment to new key (insert)
p.city = "oslo"
print(p.city)         -- oslo

-- assignment with computed key
local t = {}
t["k"] = 42
print(t.k)            -- 42
t[1] = "one"
t[2] = "two"
print(t[1])           -- one
print(t[2])           -- two
print(#t)             -- 2

-- delete by assigning nil
t[1] = nil
print(#t)             -- 0  (no border at all since t[1] is nil)
print(t[2])           -- two

-- nested tables
local nested = {inner = {x = 1, y = 2}}
print(nested.inner.x) -- 1
print(nested.inner.y) -- 2

-- tables as values across function boundaries
local function make_pair(a, b)
  return {first = a, second = b}
end
local pair = make_pair("hello", "world")
print(pair.first .. " " .. pair.second)  -- hello world

-- table with [expr] = value constructor entry
local syms = {[1+1] = "two", ["k" .. "ey"] = "value"}
print(syms[2])        -- two
print(syms.key)       -- value
