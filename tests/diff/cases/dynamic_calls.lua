-- Calls whose callee is only known at run time (methods, functions stored in
-- tables, closures passed around, metamethods) in single-value contexts:
-- argument adjustment (missing -> nil, extra dropped but evaluated), result
-- truncation, varargs, __call, proper tail calls, error levels and the stack
-- overflow guard must all behave as in reference Lua.
local log = {}
local function note(x) log[#log + 1] = tostring(x); return x end

local O = {}
O.__index = O
function O.new(v) return setmetatable({v = v}, O) end
function O:get() return self.v end
function O:add(a) return self.v + a end
function O:add3(a, b, c) return self.v + a + (b or 0) + (c or 0) end
function O:many(a, b, c, d, e) return (a or 0) + (b or 0) + (c or 0) + (d or 0) + (e or 0) end
function O:multi() return 1, 2, 3 end
function O:none() end
function O:nothing() return end
local o = O.new(10)
print(o:get(), o:add(1), o:add3(1), o:add3(1, 2, 3), o:many(1, 2, 3, 4, 5))
local m = o:multi()
local n = o:none()
print(m, n, o:nothing(), select("#", o:nothing()), select("#", (o:nothing())))
print(o:add(note(1), note(2), note(3)), table.concat(log, ","))

-- functions stored in tables and passed around
local fs = {
  function() return "zero" end,
  function(a) return a end,
  function(a, b) return a, b end,
  function(...) return select("#", ...), ... end,
}
local x0 = fs[1]()
local x1 = fs[2](5, 6, 7)
local x2 = fs[3](8)
local xv = fs[4]()
local xv2 = fs[4](nil, nil, nil)
local xv3 = fs[4](1, 2, 3, 4, 5, 6)
print(x0, x1, x2, xv, xv2, xv3)
local function apply(f, ...) local r = f(...) return r end
print(apply(fs[2], "a", "b"), apply(fs[4]), apply(fs[4], 1, 2, 3, 4, 5))
local function count(...) return select("#", ...) end
local cf = count
print(cf(), cf(nil), cf(1, nil), cf(1, 2, 3, 4), cf(1, 2, 3, 4, 5))

-- __call objects
local callable = setmetatable({}, {__call = function(self, a, b) return (a or 0) * 10 + (b or 0) end})
local c1 = callable(4, 2)
local c2 = callable()
print(c1, c2)
local okn, errn = pcall(function() local v = (nil)(1) return v end)
print(okn, errn:find("attempt to call") ~= nil) -- wording isn't asserted
local okc, errc = pcall(function() local t = {}; local v = t.missing(1) return v end)
print(okc, errc:find("attempt to call") ~= nil)

-- proper tail calls through dynamic callees stay in constant stack
local S = {}
function S.down(k) if k == 0 then return "bottom" end return S.down(k - 1) end
function S:mdown(k) if k == 0 then return "mbottom" end return self:mdown(k - 1) end
function S.vdown(k, ...) if k == 0 then return select("#", ...) end return S.vdown(k - 1, ...) end
function S.wide(k, a, b, c, d, e) if k == 0 then return a + b + c + d + e end return S.wide(k - 1, a, b, c, d, e) end
local r1 = S.down(300000)
local r2 = S:mdown(300000)
local r3 = S.vdown(300000, 1, 2)
local r4 = S.wide(300000, 1, 2, 3, 4, 5)
print(r1, r2, r3, r4)

-- error levels and positions through dynamic calls
local E = {}
function E.fail(msg) error(msg, 2) end
function E.caller() local v = E.fail("boom") return v end
local ok1, e1 = pcall(E.caller)
print(ok1, (e1:gsub("^.-:(%d+):", "%1:")))
function E.deep(k) if k == 0 then error("at bottom") end local v = E.deep(k - 1) return v end
local ok2, e2 = pcall(E.deep, 5)
print(ok2, (e2:gsub("^.-:(%d+):", "%1:")))
local R = {}
function R.inf(k) local v = R.inf(k + 1) return v end
local ok3, e3 = pcall(R.inf, 1)
print(ok3, e3:find("stack overflow") ~= nil)

-- metamethods and library callbacks
local V = {}
V.__index = V
local function vec(x, y) return setmetatable({x = x, y = y}, V) end
V.__add = function(a, b) return vec(a.x + b.x, a.y + b.y) end
V.__unm = function(a) return vec(-a.x, -a.y) end
V.__eq = function(a, b) return a.x == b.x and a.y == b.y end
V.__lt = function(a, b) return a.x < b.x end
V.__le = function(a, b) return a.x <= b.x end
V.__len = function(a) return 2 end
V.__concat = function(a, b) return tostring(a) .. "|" .. tostring(b) end
V.__tostring = function(a) return "(" .. a.x .. "," .. a.y .. ")" end
local p, q = vec(1, 2), vec(3, 4)
local s = p + q
print(tostring(s), tostring(-p), p == vec(1, 2), p < q, q <= p, #p, p .. q)
local lazy = setmetatable({}, {__index = function(t, k) return k .. "!" end,
                               __newindex = function(t, k, v) rawset(t, k, v * 2) end})
lazy.z = 21
print(lazy.a, lazy[1], lazy.z)
local arr = {5, 3, 9, 1, 7}
table.sort(arr, function(a, b) return a > b end)
print(table.concat(arr, " "))
print((string.gsub("abc", "%w", function(ch) return ch:upper() .. "." end)))

-- a metamethod may itself be a callable table (was an illegal-cast trap)
local callme = setmetatable({}, {__call = function(self, a, b) return "called" end})
local obj = setmetatable({}, {__add = callme, __lt = callme, __len = callme, __concat = callme, __unm = callme})
print(obj + 1, obj < obj, #obj, obj .. "x", -obj)
