-- Tables that are built the same way share their key layout internally; one
-- of them adding, deleting or re-adding keys, turning into a dictionary
-- (many keys, non-string keys) or storing floats must never be visible in
-- another. Key listings are sorted: pairs order is not part of the contract.
local function dump(t)
  local ks = {}
  for k in pairs(t) do ks[#ks + 1] = k end
  table.sort(ks, function(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then return ta < tb end
    if ta == "number" or ta == "string" then return a < b end
    return tostring(a) < tostring(b)
  end)
  local out = {}
  for _, k in ipairs(ks) do
    local v = t[k]
    out[#out + 1] = (type(k) == "table" and "tbl" or tostring(k)) .. "=" ..
                    (type(v) == "table" and "tbl" or tostring(v))
  end
  return table.concat(out, " ")
end

-- many records with the same layout, then one diverges
local recs = {}
for i = 1, 5 do recs[i] = {x = i, y = i * 2, name = "r" .. i} end
recs[2].z = "extra"
recs[3].y = nil
recs[4].x = nil; recs[4].x = 40
recs[5].name = nil; recs[5].w = 1; recs[5].name = "back"
for i = 1, 5 do print(i, dump(recs[i])) end

-- the same keys added in different orders, incrementally
local a, b = {}, {}
a.p = 1; a.q = 2; a.r = 3
b.r = 3; b.q = 2; b.p = 1
print(dump(a), dump(b), a.p == b.p, a.r == b.r)

-- clearing fields during traversal of a shared-layout table
local c = {k1 = 1, k2 = 2, k3 = 3, k4 = 4}
local twin = {k1 = 10, k2 = 20, k3 = 30, k4 = 40}
local seen = 0
for k in pairs(c) do c[k] = nil; seen = seen + 1 end
print(seen, next(c), dump(twin))
c.k2 = "again"
print(dump(c), dump(twin))

-- growing past the record limit into a dictionary, then shrinking
local d = {}
for i = 1, 60 do d["f" .. i] = i end
local sum = 0
for _, v in pairs(d) do sum = sum + v end
print("dict", sum, d.f1, d.f33, d.f60)
for i = 1, 60, 2 do d["f" .. i] = nil end
local cnt = 0
for _ in pairs(d) do cnt = cnt + 1 end
print("dict after deletes", cnt, d.f1, d.f2, d.f60)
for i = 1, 60, 2 do d["f" .. i] = -i end
sum = 0
for _, v in pairs(d) do sum = sum + v end
print("dict refilled", sum)

-- non-string keys arriving in a table that had only string keys
local m = {a = 1, b = 2}
local same = {a = 1, b = 2}
m[1.5] = "float"; m[true] = "bool"; m[m] = "self"; m[2^40] = "big"; m[-3] = "neg"
print(dump(m), dump(same), m[1.5], m[true], m[m], m[2^40], m[-3])

-- constant and computed string keys are the same key
local s = {alpha = 1}
local key = ("xalpha"):sub(2)
s[key] = 2
local s2 = {}
s2[key] = "first"; s2.alpha = "second"
print(s.alpha, s[key], dump(s), dump(s2))

-- unboxed float fields in shared layouts
local pts = {}
for i = 1, 4 do pts[i] = {x = i + 0.5, y = 0.25} end
for step = 1, 3 do
  for i = 1, 4 do
    local p = pts[i]
    p.x = p.x * 1.5
    p.y = p.y + p.x
  end
end
pts[2].z = 9.75
pts[3].x = "str"
for i = 1, 4 do print("pt", i, dump(pts[i])) end

-- metatables on tables sharing a layout
local Base = {greet = function(self) return "hi " .. self.name end}
Base.__index = Base
local o1 = setmetatable({name = "o1", age = 1}, Base)
local o2 = setmetatable({name = "o2", age = 2}, Base)
local plain = {name = "plain", age = 3}
o2.greet = function(self) return "override " .. self.name end
print(o1:greet(), o2:greet(), plain.greet, rawget(o1, "greet"))
local log = {}
local guarded = setmetatable({name = "g", age = 4}, {__newindex = function(t, k, v) log[#log + 1] = k; rawset(t, k, v) end})
guarded.name = "g2"; guarded.extra = 1; guarded.extra = 2; guarded.age = nil; guarded.age = 5
print(dump(guarded), table.concat(log, ","))

-- table.create with a record hint
local tc = table.create(0, 8)
tc.a = 1; tc.b = 2
print(dump(tc), #tc)

-- churn: a set of dynamic keys, inserted and removed many times
local set = {}
for round = 1, 30 do
  for i = 1, 20 do set["k" .. (round * 7 + i) % 50] = round end
  for i = 1, 10 do set["k" .. (round * 3 + i) % 50] = nil end
end
local live, total = 0, 0
for _, v in pairs(set) do live = live + 1; total = total + v end
print("churn", live, total)
