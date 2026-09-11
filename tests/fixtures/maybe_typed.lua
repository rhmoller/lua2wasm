-- Values that come out of tables, calls and `or` chains feed arithmetic and
-- comparisons through "maybe-typed" locals (docs/design/22): speculated int
-- or float with a boxed fallback. Everything here must behave exactly as
-- reference Lua whatever the speculation guessed, at -O1 and -O0.

local t = {i = 7, f = 2.5, s = "10", big = 1 << 40, neg = -3, z = 0}
local mt = setmetatable({}, {
  __add = function(a, b) return "add-mm" end,
  __lt = function(a, b) return true end,
  __eq = function(a, b) return true end,
  __unm = function(a) return "neg-mm" end,
})
t.obj = mt

-- int / float / mixed arithmetic on loaded values
local i, f = t.i, t.f
local a = i + 1
local b = f * 2
local c = i * f
local d = i / 2
local e = i // 2
local g = i % 4
local h = -i
print(a, b, c, d, e, g, h, math.type(a), math.type(c), math.type(d), math.type(e))
print(f // 1, f % 1, -f, i ^ 2, f ^ 2, 7 // -2, -7 % 3, 7.5 // -2, -7.5 % 3)

-- values that turn out not to be numbers take the generic path
local s = t.s
print(s + 1, s * 2, "3" + s, math.type(s + 1), -s)
local o = t.obj
print(o + 1, 1 + o, -o, o < 1, o == 1, o ~= 1)
local n = t.missing
print((pcall(function() return n + 1 end)), (pcall(function() local q = t.z; return i // q end)),
      (pcall(function() local q = t.z; return i % q end)))
print(i / t.z, -i / t.z, t.z / t.z ~= t.z / t.z)

-- comparisons: same type, mixed int/float (exact), strings, bools
local x, y = t.i, t.f
print(x < y, x <= y, x > y, x >= y, x == y, x ~= y)
local seven_f = t.i + 0.0
print(x == seven_f, x < seven_f, x <= seven_f, seven_f == x)
local big = t.big
local bigf = big + 0.0
print(big == bigf, big < bigf, (big + 1) == bigf, 2^53 == (1 << 53), (1 << 53) + 1 == 2^53, 2^53 < (1 << 53) + 1)
local s1, s2 = t.s, "9"
print(s1 < s2, s1 == "10", s1 == 10)
print((pcall(function() return s1 < x end)))

-- a slot that changes type over its lifetime
local v = t.i
v = v + 1
v = v * 1.5
print(v, math.type(v))
v = v .. "!"
print(v, #v)
v = t.f
print(v + 1)

-- integer wraparound and boundaries through loads
local mx = t.big * (1 << 23)         -- 2^63: wraps to mininteger
print(mx, mx == math.mininteger, mx - 1 == math.maxinteger)
local m = math.maxinteger
local mm = m + 1
print(mm, mm == math.mininteger, -mm == mm)
local one_i, one_f = 1, 1.0
print(one_i == one_f, one_i < one_f, one_i <= one_f)

-- `or` idiom, calls and method calls as sources
local function get(k) return t[k] end
local cnt = t.count or 0
cnt = cnt + get("i")
local obj = {n = 3, inc = function(self, k) return self.n + k end}
cnt = cnt + obj:inc(2)
print(cnt, math.type(cnt))

-- maybe values crossing boundaries: table store, call argument, return, concat
local out = {}
local acc = t.f
for k = 1, 3 do
  acc = acc + (t[k] or 0)      -- t[k] is nil here: the `or` idiom feeds a float
  out[k] = acc * 2
end
print(out[1], out[2], out[3], tostring(acc), acc .. "", select("#", acc, acc))
local function twice(q) return q * 2 end
print(twice(acc), twice(t.i), twice(t.s))

-- nested arithmetic with loads inside, nbody-style
local bodies = {{x = 1.0, vx = 0.5, m = 2}, {x = 3.0, vx = -0.25, m = 1}}
local dt = 0.1
for step = 1, 3 do
  for j = 1, #bodies do
    local bj = bodies[j]
    local dx = bj.x - bodies[1].x
    local mag = dt / (dx * dx + 1)
    bj.vx = bj.vx - dx * bj.m * mag
    bj.x = bj.x + dt * bj.vx
  end
end
print(string.format("%.6f %.6f %.6f %.6f", bodies[1].x, bodies[1].vx, bodies[2].x, bodies[2].vx))

-- fannkuch-style: int array values in comparisons and index arithmetic
local p = {3, 1, 2}
local q1 = p[1]
if q1 >= 3 then print("ge", q1) end
if q1 ~= 1 then
  local i2, j2 = 2, q1 - 1
  print(i2, j2, i2 >= j2, p[q1], p[j2])
end
local flips = 0
repeat
  local qq = p[q1]
  if qq == 1 then break end
  p[q1] = q1
  q1 = qq
  flips = flips + 1
until false
print(flips, q1, p[1], p[2], p[3])
