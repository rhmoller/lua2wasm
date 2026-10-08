-- Tables whose integer sequence gets holes punched into it (a nil written
-- into the middle) must keep behaving like Lua tables: reads of the hole are
-- nil and fall through to __index, writes to it fire __newindex, traversal
-- skips it (and may clear fields as it goes), # returns a border, and the
-- table library works across it. Aggregates are order-independent; `#` is
-- printed only where the border is unique, otherwise checked to be a border.
local function is_border(t, n)
  return (n == 0 or t[n] ~= nil) and t[n + 1] == nil
end
local function keys(t)
  local ks = {}
  for k in pairs(t) do ks[#ks + 1] = k end
  table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
  return table.concat(ks, ",")
end

-- interior holes, then refill
local t = {}
for i = 1, 10 do t[i] = i end
t[3] = nil; t[7] = nil
print(t[3], t[7], t[10], is_border(t, #t), keys(t))
t[3] = 30
print(t[3], is_border(t, #t), keys(t))

-- deleting from the end trims back over earlier holes: the border is unique
t = {}
for i = 1, 8 do t[i] = i end
t[5] = nil; t[6] = nil; t[7] = nil; t[8] = nil
print(#t, t[4], t[5], keys(t))
t[5] = "five"
print(#t, keys(t))

-- compaction then clearing the tail upward (the particle-list idiom)
local alive = {}
for i = 1, 20 do alive[i] = i end
for frame = 1, 3 do
  local w = 0
  for i = 1, #alive do
    local id = alive[i]
    if id % (frame + 1) ~= 0 then w = w + 1; alive[w] = id end
  end
  for i = w + 1, #alive do alive[i] = nil end
  print(frame, #alive, table.concat(alive, " "))
end

-- clearing every field during traversal
t = {}
for i = 1, 6 do t[i] = i * 1.5 end
t.x = "x"
local n = 0
for k in pairs(t) do t[k] = nil; n = n + 1 end
print(n, next(t), #t)

-- next() continues past holes; invalid keys still raise
t = {1, 2, 3, 4}
t[2] = nil
print(next(t, 1))
local okn, errn = pcall(next, {1, 2, 3}, 100)
print(okn, (errn:gsub("^.-:%d+: ", ""))) -- chunk-name formatting isn't asserted

-- __index / __newindex see a hole as an absent key, for every key form
local log = {}
t = setmetatable({}, {
  __index = function(_, k) return "dflt" .. tostring(k) end,
  __newindex = function(tb, k, v) log[#log + 1] = tostring(k); rawset(tb, k, v) end,
})
for i = 1, 5 do rawset(t, i, i) end
t[2] = nil
local k2, kf = 2, 2.0
print(t[2], t[k2], t[kf], rawget(t, 2))
t[2] = "back"
print(t[2], table.concat(log, ","))

-- ipairs stops at the first hole
t = {1, 2, 3, 4, 5}
t[3] = nil
local c = 0
for _ in ipairs(t) do c = c + 1 end
print("ipairs", c)

-- table library across holes. With interior holes several borders are
-- valid (reference Lua picks one via an internal hint), so insert/remove are
-- checked against a model that uses whatever # returned.
local function check_insert(t, pos, v)
  local n = #t
  local old = {}
  for i = 1, n + 1 do old[i] = t[i] end
  table.insert(t, pos, v)
  local ok = t[pos] == v
  for i = 1, pos - 1 do ok = ok and t[i] == old[i] end
  for i = pos, n do ok = ok and t[i + 1] == old[i] end
  return ok
end
local function check_remove(t, pos)
  local n = #t
  local old = {}
  for i = 1, n + 1 do old[i] = t[i] end
  local r = table.remove(t, pos)
  local ok = r == old[pos] and t[n] == nil
  for i = pos, n - 1 do ok = ok and t[i] == old[i + 1] end
  return ok
end
t = {1, 2, 3, 4, 5, 6, 7, 8}
t[3] = nil
print(check_insert(t, 1, "a"), check_insert(t, 2, "b"), is_border(t, #t))
print(check_remove(t, 1), check_remove(t, 2), check_remove(t, #t), is_border(t, #t))
t = {1, 2, 3, 4, 5, 6}
t[6] = nil; t[5] = nil
print(table.remove(t), #t, t[3])
table.insert(t, 2, "x")
print(#t, table.concat(t, " "))
t[2] = nil
local okc, errc = pcall(table.concat, t, ",", 1, 3)
print(okc, errc:find("concat") ~= nil) -- error wording isn't asserted
local m = {1, 2, 3, 4, 5, 6}
table.move({7, nil, 9}, 1, 3, 4, m)
print(m[4], m[5], m[6], is_border(m, #m))
local u = {1, 2, nil, 4}
print(select("#", table.unpack(u, 1, 4)), table.unpack(u, 1, 4))

-- floats stored unboxed survive holes
local f = {}
for i = 1, 8 do f[i] = i * 0.5 end
f[3] = nil; f[8] = nil
local s = 0
for i = 1, 8 do s = s + (f[i] or 0) end
print(s, is_border(f, #f), f[7])

-- a queue: front deletions, back appends, many times over
local q, head, tail = {}, 1, 0
local total = 0
for round = 1, 50 do
  for i = 1, 200 do tail = tail + 1; q[tail] = round * 1000 + i end
  for _ = 1, 150 do total = total + q[head]; q[head] = nil; head = head + 1 end
end
local left = 0
for _ in pairs(q) do left = left + 1 end
print("queue", total, left, tail - head + 1, q[head], q[tail])

-- a stack via #t
local st = {}
for i = 1, 100 do st[#st + 1] = i end
for _ = 1, 60 do st[#st] = nil end
print("stack", #st, st[#st])
