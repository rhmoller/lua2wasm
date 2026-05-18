-- Stress the open-addressing hash with mixed key types.

-- Integer keys, dense. Triggers several index grows.
local t = {}
for i = 1, 100 do t[i] = i * 10 end
print(t[1], t[50], t[100])  -- 10  500  1000

-- String keys. Exercises the FNV hash path.
local s = {}
for i = 1, 50 do s["k" .. i] = i end
print(s.k1, s.k25, s.k50)   -- 1 25 50

-- Float-equals-int keys must collide (Lua rule).
local f = {}
f[1] = "int"
print(f[1.0])               -- int
f[1.0] = "float"
print(f[1])                 -- float

-- Boolean keys.
local b = { [true] = "T", [false] = "F" }
print(b[true], b[false])    -- T F

-- Table-as-key (non-hashable; falls into bucket 0, linear-probes).
local k1, k2 = {}, {}
local r = {}
r[k1] = "first"
r[k2] = "second"
print(r[k1], r[k2])         -- first second

-- Deletion: t[k] = nil removes; subsequent lookup is nil. The index
-- rebuild after delete must keep the surviving keys findable.
t[50] = nil
print(t[50], t[51], t[100]) -- nil 510 1000

-- Length after some deletes — the array-border rule.
print(#t)                   -- 49 (first nil seen at index 50)
