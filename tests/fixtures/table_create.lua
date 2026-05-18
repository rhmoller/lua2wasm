-- table.create(nseq [, nrec]) — fresh empty table, pre-sized storage.

-- Starts empty (n=0), even with large pre-sizing.
local t = table.create(100)
print(#t)                            -- 0
print(t[1])                          -- nil

-- Fills up without surprises.
for i = 1, 100 do t[i] = i * 2 end
print(#t, t[1], t[50], t[100])       -- 100   2   100   200

-- nseq + nrec hint form: both reserve capacity.
local u = table.create(5, 10)
print(#u)                            -- 0
u.a = 1; u.b = 2; u[1] = "x"
print(#u, u.a, u[1])                 -- 1   1   x

-- nseq = 0 is fine.
local v = table.create(0)
print(#v)                            -- 0
v[1] = "ok"
print(v[1])                          -- ok

-- Each call returns a fresh, distinct table.
local a = table.create(1)
local b = table.create(1)
print(rawequal(a, b))                -- false
