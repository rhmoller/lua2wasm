-- Generic-for iteration (ipairs, pairs, a closure iterator) against a numeric
-- for over the same table, on optimized code (third run timed).
-- Compare with reference Lua: scripts/micro.sh bench/micro/iter.lua
local clock = os.clock
local function bench(name, f)
  f(); f()
  local t = clock()
  local r = f()
  print(string.format("%-26s %7.1f ms   %s", name, (clock() - t) * 1000, tostring(r)))
end
local t = {}
for i = 1, 100000 do t[i] = i end
local h = {}
for i = 1, 100000 do h["k" .. i] = i end
bench("numeric for t[i]", function() local s = 0 for r = 1, 20 do for i = 1, #t do s = s + t[i] end end return s end)
bench("ipairs(t)", function() local s = 0 for r = 1, 20 do for _, v in ipairs(t) do s = s + v end end return s end)
bench("pairs(t) array", function() local s = 0 for r = 1, 20 do for _, v in pairs(t) do s = s + v end end return s end)
bench("pairs(h) hash", function() local s = 0 for r = 1, 20 do for _, v in pairs(h) do s = s + v end end return s end)
bench("closure iterator", function()
  local function range(n) local i = 0 return function() i = i + 1 if i <= n then return i end end end
  local s = 0 for r = 1, 20 do for v in range(100000) do s = s + v end end return s end)
