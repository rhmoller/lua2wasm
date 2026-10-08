-- Builtins with a fast entry ($LuaFn1: arguments in registers, one result)
-- called with every argument count the fast entry takes (0-4), plus five
-- (the generic entry), and the error paths, compared with the same calls
-- through pcall (the generic entry).

local function both(name, f, ...)
  local fast = {pcall(function(...) local r = f(...) return r end, ...)}
  local slow = {pcall(f, ...)}
  print(name, fast[1], fast[1] and tostring(fast[2]) or "err", slow[1], slow[1] and tostring(slow[2]) or "err")
end

both("max0", math.max)
both("max1", math.max, 3)
both("max2", math.max, 3, 7.5)
both("max3", math.max, 3, 9, 7)
both("max4", math.max, 1, 2, 3, 4)
both("max5", math.max, 1, 2, 3, 4, 5)
both("maxint", math.max, 2, 2.0)
both("min2", math.min, 3, -7.5)
both("min4", math.min, 4, 3, 2, 1)
both("min5", math.min, 5, 4, 3, 2, 1)
both("floor", math.floor, 3.7)
both("floor-", math.floor, -3.2)
both("floorint", math.floor, 5)
both("floorstr", math.floor, "2.5")
both("floorbig", math.floor, 1e300)
both("floorerr", math.floor, {})
both("ceil", math.ceil, 3.2)
both("abs", math.abs, -4)
both("absmin", math.abs, math.mininteger)
both("absf", math.abs, -0.5)
both("sqrt", math.sqrt, 16)
both("sin", math.sin, 0)
both("cos", math.cos, 0)
both("type0", type)
both("type1", type, nil)
both("type2", type, {}, 1)
both("tostring0", tostring)
both("tostring1", tostring, 1.5)
both("tostringnil", tostring, nil)
both("tostringmm", tostring, setmetatable({}, {__tostring = function() return "custom" end}))

-- setmetatable: returns its table; checks both arguments and __metatable
local t = {}
local mt = {__index = function(_, k) return k .. "!" end}
print("setmt", setmetatable(t, mt) == t, t.x)
print("setmt nil", setmetatable(t, nil) == t, getmetatable(t))
print("setmt bad", pcall(setmetatable, 1, {}), (pcall(setmetatable, {}, 1)))
local locked = setmetatable({}, {__metatable = "locked"})
print("setmt locked", pcall(setmetatable, locked, {}))
local made = {}
for i = 1, 5 do made[i] = setmetatable({i}, mt) end
print("setmt loop", made[3][1], made[5].y)

-- table.insert: the append form is fast, the others go generic
local q = {}
for i = 1, 5 do table.insert(q, i * i) end
table.insert(q, 1, 0)
table.insert(q, 3, 99)
print("insert", table.concat(q, " "))
print("insert errs", pcall(table.insert, q), pcall(table.insert, q, 1, 2, 3), pcall(table.insert, 5, 1),
  (pcall(table.insert, q, 100, 1)))
local proxy = setmetatable({}, {__newindex = function(t, k, v) rawset(t, k, v * 10) end})
table.insert(proxy, 4)
print("insert __newindex", proxy[1])
