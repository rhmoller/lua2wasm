-- The main chunk's loops run in functions of their own that return every so
-- many iterations and are called again (src/codegen/outline.c); the suite
-- also runs with a budget of one iteration, so every iteration crosses a
-- suspension. None of it may be observable.

-- numeric for: integer, float, negative step, variable step, non-integer limit
local isum = 0
for i = 1, 100 do isum = isum + i end
local fsum = 0.0
for x = 0.5, 10, 0.25 do fsum = fsum + x end
local down = {}
for i = 10, 1, -3 do down[#down + 1] = i end
local st, stepped = 2, {}
for i = 1, 9, st do stepped[#stepped + 1] = i end
local lim = 0
for i = 1, 3.5 do lim = lim + i end
print(isum, fsum, table.concat(down, ","), table.concat(stepped, ","), lim)

-- the bounds are evaluated once, before the first iteration
local calls = 0
local function bound(v) calls = calls + 1; return v end
for i = bound(1), bound(5), bound(2) do end
print("bound calls", calls)

-- while and repeat over outer locals; until sees the body's locals
local n, steps = 27, 0
while n ~= 1 do
  if n % 2 == 0 then n = n // 2 else n = 3 * n + 1 end
  steps = steps + 1
end
local k = 0
repeat local sq = k * k; k = k + 1 until sq > 50
print("collatz", steps, "repeat", k)

-- generic for: ipairs, pairs, a stateful iterator
local t = {}
for i = 1, 20 do t[i] = i * i end
local s = 0
for _, v in ipairs(t) do s = s + v end
local keys = 0
for _ in pairs({a = 1, b = 2, c = 3}) do keys = keys + 1 end
local function range(a, b) local i = a - 1 return function() i = i + 1 if i <= b then return i end end end
local r = {}
for v in range(3, 7) do r[#r + 1] = v end
print(s, keys, table.concat(r, " "))

-- break, goto continue, a backward goto inside the body, a goto out of the loop
local found
for i = 1, 1000 do
  if i * i > 300 then found = i break end
end
local odd = {}
for i = 1, 10 do
  if i % 2 == 0 then goto continue end
  odd[#odd + 1] = i
  ::continue::
end
local tries_log = {}
for i = 1, 3 do
  local tries = 0
  ::again::
  tries = tries + 1
  if tries < i then goto again end
  tries_log[#tries_log + 1] = tries
end
local left_at
for i = 1, 10 do
  left_at = i
  if i == 4 then goto out end
end
::out::
print("found", found, table.concat(odd, ","), table.concat(tries_log, ","), left_at)

-- closures over the loop variable (fresh each iteration) and over outer locals
local fns = {}
local shared = 0
for i = 1, 5 do
  fns[i] = function() shared = shared + i; return i end
end
for _, f in ipairs(fns) do f() end
local counter = 0
local function get() return counter end
for i = 1, 5 do counter = counter + i end
local kfns = {}
for key in pairs({x = true}) do kfns[#kfns + 1] = function() return key end end
print("shared", shared, fns[2](), fns[5](), "counter", get(), kfns[1]())

-- outer locals whose type changes inside the loop
local acc = 1
for i = 1, 10 do
  if i == 5 then acc = acc / 2 else acc = acc + i end
end
local m = 0
for i = 1, 6 do m = m + (i % 2 == 0 and 0.5 or 1) end
local any = 1
for i = 1, 4 do if i == 2 then any = "str" elseif i == 4 then any = any .. "!" end end
print("acc", acc, math.type(acc), "m", m, math.type(m), any)

-- nested loops
local grid = 0
for y = 1, 30 do
  for x = 1, 30 do
    if (x + y) % 7 == 0 then grid = grid + x * y end
  end
end
print("grid", grid)

-- to-be-closed values: a <close> local in the body, a generic for's closing value
local log = {}
local function closer(name) return setmetatable({}, {__close = function() log[#log + 1] = name end}) end
for i = 1, 3 do
  local c <close> = closer("body" .. i)
  log[#log + 1] = "iter" .. i
end
local function iter_with_close()
  local i = 0
  return function() i = i + 1; if i <= 2 then return i end end, nil, nil, closer("for-close")
end
for v in iter_with_close() do log[#log + 1] = "v" .. v end
for v in iter_with_close() do if v == 1 then break end end
print(table.concat(log, " "))

-- long loops cross many suspensions at the default budget too
local big = 0
for i = 1, 300000 do big = big + (i % 3) end
local w, j = 0, 0
while j < 200000 do j = j + 1; w = w + (j & 1) end
local cells = {}
for i = 1, 100000 do cells[i] = i % 7 end
local csum = 0
for _, v in ipairs(cells) do csum = csum + v end
print("big", big, "w", w, "csum", csum)

-- returning from the main chunk inside a loop ends the program
for i = 1, 10 do
  if i == 3 then print("returning at", i) return end
end
print("not reached")
