local t0 = os.clock()
-- higher-order functions, closures, iterators, pairs/ipairs
local function map(t, f) local r = {} for i = 1, #t do r[i] = f(t[i]) end return r end
local function filter(t, f) local r = {} for i = 1, #t do if f(t[i]) then r[#r+1] = t[i] end end return r end
local function reduce(t, f, a) for i = 1, #t do a = f(a, t[i]) end return a end
local function range(n) local i = 0 return function() i = i + 1 if i <= n then return i end end end
local function counter() local c = 0 return function() c = c + 1 return c end end
local total = 0
for rep = 1, 200 do
  local xs = {}
  for i in range(5000) do xs[#xs+1] = i end
  local ys = map(xs, function(x) return x * 2 end)
  local zs = filter(ys, function(x) return x % 3 == 0 end)
  total = total + reduce(zs, function(a, b) return a + b end, 0)
  local c = counter()
  for _ = 1, 1000 do c() end
  total = total + c()
  local m = {}
  for i, v in ipairs(zs) do m["k" .. (i % 100)] = v end
  for k, v in pairs(m) do total = total + v end
end
io.write(total, "\n")
io.write(string.format("TIME %.3f\n", os.clock()-t0))
