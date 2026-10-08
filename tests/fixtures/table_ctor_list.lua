-- `{v1, ..., vn}` builds its array part from one array ($tab_new_arr): the
-- values before the first nil; any after a nil are stored one by one, so
-- the layout (and `#`, pairs order) is what the stores would have made.

local function show(name, t, n)
  local parts = {}
  for k, v in pairs(t) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
  table.sort(parts)
  local ip = 0
  for _ in ipairs(t) do ip = ip + 1 end
  print(name, #t, ip, table.concat(parts, " "))
end

local x, y = nil, 7
show("plain", {1, 2, 3})
show("one", {"a"})
show("mid nil", {1, nil, 3})
show("lead nil", {nil, 2})
show("trail nil", {1, 2, nil})
show("all nil", {nil, nil})
show("vars", {y, x})
show("vars2", {y, y, x})
show("floats", {1.5, 2, 3.25})
show("strings", {"a", "b", "c"})

-- values are evaluated left to right, single-valued except a last call
local log = {}
local function f(v) log[#log + 1] = v; return v, "extra" end
local t = {f(1), f(2), f(3)}
print("order", table.concat(log, ","), #t, t[3])
local spread = {f(4), f(5)}
print("spread", #spread, spread[2], spread[3])

-- nested lists, and growing a list afterwards
local tree = {{1, 2}, {3, {4, 5}}}
print("nested", tree[1][2], tree[2][2][1], #tree[2][2])
local grow = {10, 20}
grow[#grow + 1] = 30
grow[5] = 50
grow[4] = 40
print("grow", #grow, table.concat(grow, ","))
local holes = {1, nil, 3}
holes[2] = 2
print("filled", #holes, table.concat(holes, ","))
table.insert(holes, 4)
print("insert", #holes, holes[4])
local shrink = {1, 2, 3}
shrink[3] = nil
shrink[2] = nil
print("shrink", #shrink, shrink[1])
local mt = setmetatable({1, 2}, {__index = function(_, k) return "mm" .. k end})
print("meta", mt[1], mt[3])
