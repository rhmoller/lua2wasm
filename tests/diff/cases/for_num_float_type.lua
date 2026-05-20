-- Numeric-for typing (Lua 5.4+): the loop runs with integers iff the initial
-- value AND the step are both integers; otherwise the control variable is a
-- float from the first iteration. The limit's type does not matter.
local function show(t)
  local s = {}
  for _, v in ipairs(t) do s[#s + 1] = math.type(v) .. ":" .. tostring(v) end
  return table.concat(s, ",")
end

-- int init, float step -> float loop (this was the bug: i started as 1)
local r = {}
for i = 1, 3, 1.0 do r[#r + 1] = i end
print(show(r))                          -- float:1.0,float:2.0,float:3.0

-- float init -> float loop
r = {}
for i = 1.5, 3 do r[#r + 1] = i end
print(show(r))                          -- float:1.5,float:2.5

-- int init AND int step -> integer loop, even with a float limit
r = {}
for i = 1, 3.9 do r[#r + 1] = i end
print(show(r))                          -- integer:1,integer:2,integer:3

-- descending float step
r = {}
for i = 3, 1, -1.0 do r[#r + 1] = i end
print(show(r))                          -- float:3.0,float:2.0,float:1.0

-- expression-typed bounds (float step from a variable)
local lo, hi, st = 1, 2, 0.5
r = {}
for i = lo, hi, st do r[#r + 1] = i end
print(show(r))                          -- float:1.0,float:1.5,float:2.0

-- plain integer loop unchanged
r = {}
for i = 1, 3 do r[#r + 1] = i end
print(show(r))                          -- integer:1,integer:2,integer:3
