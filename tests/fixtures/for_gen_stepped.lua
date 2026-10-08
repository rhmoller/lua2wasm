-- The generic for steps ipairs and pairs in place (no iterator call per
-- iteration: $for_gen_mode / $next_step) and calls any other iterator; one
-- loop variable calls through the iterator's fast entry. Every case here
-- must match what calling the iterator gives.

-- ipairs: array, floats, holes filled by __index, stops at the first nil
local t = {10, 20.5, 30}
for i, v in ipairs(t) do io.write(i, ":", v, " ") end print()
local proxy = setmetatable({1, nil, 3}, {__index = function(_, k) if k < 5 then return "idx" .. k end end})
for i, v in ipairs(proxy) do io.write(i, ":", v, " ") end print()
for i in ipairs({"a", "b"}) do io.write(i, " ") end print()
for i, c in ipairs("abc") do print("never", i, c) end
print("ipairs number", pcall(function() for _ in ipairs(5) do end end) == false)
local empty = 0
for _ in ipairs({}) do empty = empty + 1 end
for _ in pairs({}) do empty = empty + 1 end
print("empty", empty)

-- pairs: the same entries in the same order as calling next
local mixed = {1, 2, 3, x = "a", y = "b", [10] = "ten", [2.5] = "f"}
mixed.z = 1.25
local function by_next(tab)
  local out, k, v = {}, nil, nil
  repeat
    k, v = next(tab, k)
    if k ~= nil then out[#out + 1] = tostring(k) .. "=" .. tostring(v) end
  until k == nil
  return table.concat(out, " ")
end
local function by_pairs(tab)
  local out = {}
  for k, v in pairs(tab) do out[#out + 1] = tostring(k) .. "=" .. tostring(v) end
  return table.concat(out, " ")
end
print("pairs order", by_pairs(mixed) == by_next(mixed))
local keys = {}
for k in pairs(mixed) do keys[#keys + 1] = tostring(k) end
table.sort(keys)
print("pairs keys", table.concat(keys, " "))

-- explicit next, a starting key, and three variables use the call protocol
local n = 0
for k, v in next, mixed do n = n + 1 end
print("next", n)
local after = {}
for k in next, {1, 2, 3}, 1 do after[#after + 1] = k end
print("from key", table.concat(after, " "))
for a, b, c in pairs({5}) do print("three", a, b, c) end

-- clearing fields during traversal is allowed
local del = {a = 1, b = 2, c = 3, d = 4, 1, 2, 3}
local seen = 0
for k in pairs(del) do seen = seen + 1; del[k] = nil end
print("cleared", seen, next(del))
-- and so is changing existing fields
local upd = {a = 1, b = 2, 3}
for k, v in pairs(upd) do upd[k] = v * 10 end
print("updated", upd.a, upd.b, upd[1])

-- __pairs, and a closure iterator with one and two variables
local custom = setmetatable({}, {__pairs = function(t) return function(_, k) if not k then return 1, "one" end end, t, nil end})
for k, v in pairs(custom) do print("__pairs", k, v) end
local function range(lim)
  local i = 0
  return function() i = i + 1; if i <= lim then return i, i * i end end
end
local s1, s2 = 0, 0
for i in range(5) do s1 = s1 + i end
for i, sq in range(5) do s2 = s2 + sq end
print("closure", s1, s2)
local callable = setmetatable({}, {__call = function(_, _, k) k = (k or 0) + 1; if k <= 3 then return k end end})
local cs = {}
for k in callable do cs[#cs + 1] = k end
print("__call iterator", table.concat(cs, " "))

-- captured loop variables are fresh per iteration
local fns = {}
for i, v in ipairs({"x", "y"}) do fns[#fns + 1] = function() return i .. v end end
for k, v in pairs({p = 1}) do fns[#fns + 1] = function() return k .. v end end
print("captured", fns[1](), fns[2](), fns[3]())

-- nested loops and break
local pairs_seen = 0
for _, row in ipairs({{1, 2}, {3, 4, 5}}) do
  for _, x in ipairs(row) do
    if x == 4 then break end
    pairs_seen = pairs_seen + x
  end
end
print("nested", pairs_seen)

-- a long loop in the main chunk (outlined, suspended and resumed)
local big = {}
for i = 1, 70000 do big[i] = i % 7 end
big.extra = 100
local total = 0
for _, v in pairs(big) do total = total + v end
local itotal = 0
for i, v in ipairs(big) do itotal = itotal + v * (i % 2) end
print("outlined", total, itotal)
