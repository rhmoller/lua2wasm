-- hashtab: sparse integer keys, string keys, and table-as-key lookups
-- with inserts, hits, deletes and a pairs walk.
local t0 = os.clock()
-- hash tables with int keys (sparse), string keys, table keys; insert/lookup/delete
local t = {}
local seed = 1
local function rnd() seed = (seed * 1103515245 + 12345) % 2147483648 return seed end
for i = 1, 300000 do t[rnd() % 1000003] = i end
local hits = 0
for i = 1, 600000 do if t[rnd() % 1000003] then hits = hits + 1 end end
for i = 1, 300000 do t[rnd() % 1000003] = nil end
local cnt = 0 for _ in pairs(t) do cnt = cnt + 1 end
io.write(hits, " ", cnt, "\n")
local s = {}
for i = 1, 100000 do s["key" .. i] = i end
local sum = 0
for i = 1, 100000 do sum = sum + s["key" .. (i * 7 % 100000 + 1)] end
io.write(sum, "\n")
local objs, idx = {}, {}
for i = 1, 100000 do local o = {i} objs[i] = o idx[o] = i end
local sum2 = 0
for i = 1, 100000 do sum2 = sum2 + idx[objs[i]] end
io.write(sum2, "\n")
io.write(string.format("TIME %.3f\n", os.clock()-t0))
