-- `global name = value` is an initialization: it raises "global 'name'
-- already defined" when the global already holds a value (false counts; nil
-- doesn't). Every value is evaluated first, then the names are checked and
-- stored right to left, so a later name can be stored before an earlier one
-- fails. `global function f` is initialized the same way. And a function
-- statement may redefine a builtin, like an assignment can.
global *
local function strip(e) return (string.gsub(tostring(e), "^[^:]*:%d+: ", "")) end
local function try(f)
  local ok, e = pcall(f)
  print(ok, ok and "" or strip(e))
end

a = 1
try(function() global a = 2 end)
print(a)
try(function() global a, b = 10, 20 end)
print(a, b)
c = false
try(function() global c = 1 end)
print(c)
try(function() global d, e = 5 end)
print(d, e)
try(function() global d, e = 6 end)
print(d, e)

-- values first: q gets p's value from before the statement
try(function() global p, q = 3, p end)
print(p, q)
local log = {}
local function v(tag, x) log[#log + 1] = tag; return x end
try(function() global r, s, t = v("r", 1), v("s", 2), v("t", 3), v("extra", 4) end)
print(r, s, t, table.concat(log, ","))
local function two() return "x", "y" end
try(function() global u, w = two() end)
print(u, w)

-- a declaration without a value checks nothing
try(function() global a end)

-- global function
try(function() global function h() return "h" end end)
print(h())
try(function() global function h() return "again" end end)
print(h())

-- function statements redefine builtins
local old_print, old_tostring = print, tostring
function print(...) old_print("wrapped:", ...) end
print("hi", 1)
function tostring(x) return "<" .. old_tostring(x) .. ">" end
print(tostring(42))
print = old_print
tostring = old_tostring
print(tostring(42))
