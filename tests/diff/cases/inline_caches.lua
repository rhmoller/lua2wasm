-- Field and method access sites remember where they last found a key. Each
-- loop below runs one site many times while the thing it reads changes under
-- it; every iteration must see the current value, never a remembered one.
local function read_x(t) return t.x end
local function write_x(t, v) t.x = v end
local function call_m(o) return o:m() end

-- one site, many layouts (and non-tables)
local objs = {{x = 1}, {y = 2, x = 3}, {x = 4, z = 5}, setmetatable({}, {__index = {x = 6}}), {}, "str"}
local out = {}
for round = 1, 3 do
  for i = 1, #objs do
    local ok, v = pcall(read_x, objs[i])
    out[#out + 1] = tostring(ok and v)
  end
end
print(table.concat(out, " "))

-- the cached slot goes nil, then a metatable appears, then the key comes back
local t = {x = "own", y = 0}
local seq = {}
for i = 1, 6 do
  if i == 2 then t.x = nil end
  if i == 3 then setmetatable(t, {__index = function(_, k) return "dflt-" .. k end}) end
  if i == 5 then t.x = "back" end
  seq[#seq + 1] = tostring(read_x(t))
end
print(table.concat(seq, " "))

-- a dictionary whose keys move when it compacts
local d = {x = "first"}
for i = 1, 40 do d["k" .. i] = i end
local reads = {}
for round = 1, 5 do
  for i = 1, 40 do d["k" .. i] = nil end
  for i = 41 + round * 40, 80 + round * 40 do d["k" .. i] = i end
  d.x = "round" .. round
  reads[#reads + 1] = read_x(d)
end
print(table.concat(reads, " "))

-- writes through a cached slot: plain, nil, then __newindex on the absent key
local w = {x = 0, y = 0}
local log = {}
for i = 1, 5 do
  if i == 3 then write_x(w, nil); setmetatable(w, {__newindex = function(tb, k, v) log[#log + 1] = k .. "=" .. tostring(v); rawset(tb, k, v) end}) end
  write_x(w, i * 1.5)
end
print(w.x, table.concat(log, ","))

-- methods: replaced, overridden per instance, __index swapped, removed
local A = {}; A.__index = A
function A:m() return "A.m" end
local B = {}; B.__index = B
function B:m() return "B.m" end
local o = setmetatable({}, A)
local calls = {}
for i = 1, 10 do
  if i == 3 then function A:m() return "A.m2" end end
  if i == 4 then o.m = function() return "own" end end
  if i == 5 then o.m = nil end
  if i == 6 then setmetatable(o, B) end
  if i == 7 then B.__index = A end
  if i == 8 then B.__index = function(_, k) return function() return "fn-" .. k end end end
  if i == 9 then setmetatable(o, A); A.m = nil; setmetatable(A, {__index = {m = function() return "base" end}}) end
  calls[#calls + 1] = call_m(o)
end
print(table.concat(calls, " "))

-- two classes with the same layout at one call site
local P = {}; P.__index = P; function P:m() return "P" end
local Q = {}; Q.__index = Q; function Q:m() return "Q" end
local mixed = {}
for i = 1, 6 do
  local obj = setmetatable({n = i}, i % 2 == 0 and P or Q)
  mixed[#mixed + 1] = call_m(obj)
end
print(table.concat(mixed, " "))

-- a class with many methods (more than a record layout holds)
local Big = {}; Big.__index = Big
for i = 1, 40 do Big["m" .. i] = function() return i end end
function Big:m() return "big" end
local bo = setmetatable({}, Big)
local bres = {}
for i = 1, 4 do
  if i == 3 then for j = 1, 40 do Big["m" .. j] = nil end; for j = 41, 90 do Big["m" .. j] = j end end
  bres[#bres + 1] = call_m(bo)
end
print(table.concat(bres, " "))

-- string receivers and float fields through the same sites
print(pcall(call_m, "s"), read_x({x = 2.5}), read_x({x = 2^53}))
local acc = {x = 0.5}
for _ = 1, 5 do write_x(acc, read_x(acc) * 2) end
print(acc.x, math.type(acc.x))
