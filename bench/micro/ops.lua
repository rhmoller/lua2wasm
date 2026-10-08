-- Per-operation costs on optimized code: each case runs three times and the
-- third run is timed, so V8 has tiered it up (a loop in a function called
-- once would otherwise run on baseline code; see docs/perf-backlog.md).
-- Compare with reference Lua: scripts/micro.sh bench/micro/ops.lua
local clock = os.clock
local function bench(name, f)
  f(); f()
  local t = clock()
  local r = f()
  print(string.format("%-28s %7.1f ms   %s", name, (clock() - t) * 1000, tostring(r)))
end
local N = 2000000

bench("local int LCG", function()
  local seed = 42
  for i = 1, N do seed = (seed * 1103515245 + 12345) % 2147483648 end
  return seed
end)
bench("upvalue int LCG via closure", function()
  local seed = 42
  local function rnd() seed = (seed * 1103515245 + 12345) % 2147483648; return seed end
  local s = 0
  for i = 1, N do s = rnd() end
  return s
end)
bench("upvalue small counter", function()
  local c = 0
  local function inc() c = c + 1 end
  for i = 1, N do inc() end
  return c
end)
bench("s:byte(i)", function()
  local s = string.rep("abcdefgh", 1000)
  local n = 0
  for r = 1, N // #s do for i = 1, #s do n = n + s:byte(i) end end
  return n
end)
bench("t[#t+1] = i", function()
  local t = {}
  for i = 1, N do t[#t + 1] = i end
  return #t
end)
bench("t[i] = i (array)", function()
  local t = {}
  for i = 1, N do t[i] = i end
  return #t
end)
bench("str .. int", function()
  local x
  for i = 1, N // 4 do x = "k" .. i end
  return x
end)
bench("sparse int keys set+get", function()
  local t = {}
  for i = 1, N // 4 do t[(i * 7919) % 1000003] = i end
  local s = 0
  for i = 1, N // 4 do s = s + (t[(i * 7919) % 1000003] or 0) end
  return s
end)
bench("string keys set+get", function()
  local t = {}
  for i = 1, N // 20 do t["key" .. i] = i end
  local s = 0
  for i = 1, N // 20 do s = s + t["key" .. i] end
  return s
end)
bench("method call obj:m()", function()
  local C = {}; C.__index = C
  function C:m(x) return self.v + x end
  local o = setmetatable({v = 1}, C)
  local s = 0
  for i = 1, N do s = s + o:m(i) end
  return s
end)
bench("closure call f(x)", function()
  local fs = {function(x) return x + 1 end}
  local f = fs[1]
  local s = 0
  for i = 1, N do s = s + f(i) end
  return s
end)
bench("table alloc {x=,y=}", function()
  local last
  for i = 1, N // 2 do last = {x = i, y = i} end
  return last.x
end)
bench("float array sum", function()
  local t = {}
  for i = 1, 1000 do t[i] = i * 0.5 end
  local s = 0.0
  for r = 1, N // 1000 do for i = 1, 1000 do s = s + t[i] end end
  return s
end)
