-- Captured locals that only ever hold integers live in an $IBox, read and
-- written raw (src/codegen/analysis.c, "int boxes"); anything else stays a
-- boxed $Box. Both kinds side by side, including the stores that decide.

-- an RNG seed past 2^30, written by the closure, read by its parent
local seed = 1
local function rnd() seed = (seed * 1103515245 + 12345) % 2147483648; return seed end
local acc = 0
for _ = 1, 1000 do acc = acc + rnd() % 1000 end
print("rnd", acc, seed, math.type(seed))

-- wrapping arithmetic on a captured integer
local big = math.maxinteger - 2
local function bump() big = big + 1; return big end
print("wrap", bump(), bump(), bump(), big == math.mininteger)

-- a counter per call: each `local` is a fresh box
local function counter(start)
  local c = start * 2
  return function(step) c = c + step; return c end, function() return c end
end
local inc, get = counter(5)
local inc2 = counter(100)
inc(1); inc(2); inc2(7)
print("counter", get(), inc2(0))

-- fresh boxes per loop iteration
local fns = {}
for i = 1, 3 do
  local k = i * 10
  fns[i] = function() k = k + 1; return k end
end
print("per-iter", fns[1](), fns[1](), fns[2](), fns[3]())

-- a store of a float, a string or nil anywhere keeps the variable boxed
local f = 1
local function tofloat() f = f + 0.5 end
tofloat()
print("float", f, math.type(f))
local s = 7
local function tostr() s = s .. "!" end
tostr()
print("string", s)
local n = 3
local function clear() n = nil end
clear()
print("nil", n)
local d = 10
local function div() d = d / 4 end
div()
print("div", d)

-- grandchild closures through an upvalue chain
local depth = 0
local function outer()
  return function()
    return function() depth = depth + 2; return depth * 3 end
  end
end
local g = outer()()
g()
print("chain", g(), depth)

-- multiple assignment and a swap through closures
local a, b = 1, 2
local function swap() a, b = b, a end
swap()
print("swap", a, b)

-- used as a key, in a comparison, a concatenation and an int-typed call
local key = 1 << 40
local function nextkey() key = key + 1; return key end
local t = {}
t[nextkey()] = "x"
t[key] = t[key] .. "y"
local function half(x) return x // 2 end
print("uses", t[key], key > 1 << 40, "k" .. key, half(key), key % 7, -key)

-- integer floor division and modulo with negatives
local m = -7
local function mods() m = m // 2; return m % 3 end
print("mods", mods(), m, mods(), m)

-- a captured int across goto
do
  local x = 0
  local function addx(v) x = x + v end
  ::again::
  addx(1)
  if x < 5 then goto again end
  print("goto", x)
end

-- a long loop in the main chunk (outlined), its captured int declared inside
local total = 0
for i = 1, 200000 do
  local j = i % 13
  local function addj() total = total + j end
  if j == 5 then addj() end
end
print("outlined", total)

-- a to-be-closed variable is never an int box
do
  local closed = 0
  local function mark() closed = closed + 1 end
  do
    local h <close> = setmetatable({}, {__close = function() mark() end})
  end
  print("close", closed)
end
