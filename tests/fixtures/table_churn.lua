-- Insert/delete churn correctness: guards the table index against
-- tombstone/probe-chain bugs. Deterministic (no modify-during-iterate).
local t = {}
local function count() local n = 0 for _ in pairs(t) do n = n + 1 end return n end

for i = 1, 2000 do t["k" .. i] = i end
print(count())                                  -- 2000
for i = 1, 2000, 2 do t["k" .. i] = nil end     -- delete odds
print(count(), t.k2, t.k1, t.k1999, t.k2000)    -- 1000  2  nil  nil  2000
for i = 1, 2000, 2 do t["k" .. i] = -i end       -- reinsert odds
print(count(), t.k1, t.k3)                       -- 2000  -1  -3
for i = 1, 2000 do t["k" .. i] = nil end          -- delete all
print(count())                                   -- 0
t.x, t.y = 1, 2                                   -- reuse after empty
print(count(), t.x, t.y)                          -- 2  1  2

-- integer-key collision stress in a small index
local u = {}
for i = 1, 50 do u[i] = i end
for i = 1, 50, 2 do u[i] = nil end
local su = 0
for _, v in pairs(u) do su = su + v end
print(su)                                         -- 650 (evens 2..50)

-- table keys + delete
local m, a, b = {}, {}, {}
m[a], m[b] = 10, 20
m[a] = nil
print(m[a], m[b])                                 -- nil  20
