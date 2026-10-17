-- Lua 5.5 named vararg tables: in `function f(a, ...t)`, t is a read-only
-- local holding {extra args..., n = count}, and `...` is the list of t's
-- values from 1 to t.n, so changes to t show through `...`. A t.n that is
-- not an integer in range makes `...` raise "vararg table has no proper 'n'".
local function show(...) return select("#", ...), ... end

local function f(...t) return type(t), t.n, t[1], t[2], t[3], select("#", ...) end
print(f())
print(f(1, nil, 3))
print(f(nil, nil))

local function g(a, b, ...rest) return a, b, rest.n, rest[1], rest[2] end
print(g(1))
print(g(1, 2, 3, 4))

-- a fresh table per call
local function keep(...t) return t end
local k1, k2 = keep(1), keep(1)
print(k1 ~= k2, k1.n, k2[1])

-- `...` reads the table
local function edit(...t) t[1] = "changed"; t.extra = true; return t.extra, ... end
print(edit("orig", "two"))
local function shrink(...t) t.n = 1; return show(...) end
print(shrink(1, 2, 3))
local function grow(...t) t.n = 4; return show(...) end
print(grow("a"))
local function first(...t) t[1] = 10; local x = ...; local y, z = ...; return x, y, z, (...) end
print(first(1, 2))

-- `...` in every position it can appear
local function places(...t)
  local packed = {...}
  local s = 0
  for i = 1, select("#", ...) do s = s + (select(i, ...) or 0) end
  return #packed, s, show(..., "end"), show("start", ...)
end
print(places(4, 5, 6))
local function tail(...t) return show(...) end
print(tail(7, nil))
local function unpacked(...t) return table.unpack(t, 1, t.n) end
print(unpacked(1, nil, 3))
local function iter(...t) local out = {} for i, v in ipairs(t) do out[i] = v * 2 end return table.concat(out, ",") end
print(iter(1, 2, 3))
local function keys(...t)
  local ks = {}
  for key, v in pairs(t) do ks[#ks + 1] = tostring(key) .. "=" .. tostring(v) end
  table.sort(ks)
  return table.concat(ks, ",")
end
print(keys("a", "b"))

-- methods, globals, anonymous functions
local o = {}
function o:m(...args) return self == o, args.n, ... end
print(o:m(1, 2, 3))
function named_vararg_global(...xs) return xs.n end
print(named_vararg_global(1, 2))
print((function(...z) return z.n end)(5, 6, 7))

-- captured by a closure
local function cap(...t) return function() t.n = t.n + 1; return t.n end end
local c = cap(1, 2)
print(c(), c())
local function cap2(...t) local get = function() return t[1] end; t[1] = "late"; return get(), ... end
print(cap2("early", "x"))

-- shadowing the name does not change what `...` means
local function shadow(...t) local t = {n = 0}; return t.n, show(...) end
print(shadow(1, 2))
local function sameparam(a, ...a) return type(a), a.n end
print(sameparam(1, 2, 3))

-- a vararg function nested inside: its own `...`
local function outer(...t)
  local inner = function(...u) return u.n, select("#", ...) end
  return t.n, inner(9, 9, 9, 9)
end
print(outer(1))

-- recursion
local function count(n, ...t) if n == 0 then return t.n end return count(n - 1, n, ...) end
print(count(5))

-- a long loop over the table (run-once code may be outlined)
local function sum(...t)
  local s = 0
  for _ = 1, 100000 do s = s + t[1] + select("#", ...) end
  return s
end
print(sum(1, 2))

-- improper n
local function strip(e) return (string.gsub(tostring(e), "^[^:]*:%d+: ", "")) end
local function bad(v) return pcall(function(...t) t.n = v; return ... end, 1, 2) end
for _, v in ipairs({1.0, "2", -1, 2^40, true}) do
  local ok, e = bad(v)
  print(type(v), ok, strip(e))
end
local ok, e = pcall(function(...t) t.n = nil; return ... end, 1)
print(ok, strip(e))
